#if os(macOS)
import Foundation

// `claude agents --json` (PR-D1 Kit, 계약 21.1 DR-1 · 21.2 DR-S1a): 살아 있는 모든 세션의 목록을 JSON으로 내는 **문서화된** 명령이다 (agent view 문서 "List sessions as JSON").
// 모델을 부르지 않는다. 등록 파일(내부 형식)을 늘 이 값으로 맞춰 보려고 쓴다. 필요한 키만 읽는다: `pid` · `sessionId` · `status` · `waitingFor`.
// 폴더(`cwd`) · 이름(`name`) · 종류 · 시작 시각은 읽지도 담지도 않는다 (모든 세션의 폴더 · 이름이 메모리에 오지만 값으로 남기지 않는다).

public struct ClaudeAgentsItem: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var pid: Int32
    /// 소문자 정규 UUID
    public var sessionID: String
    public var state: ClaudeAppSessionState

    public init(pid: Int32, sessionID: String, state: ClaudeAppSessionState) {
        self.pid = pid
        self.sessionID = sessionID
        self.state = state
    }

    /// 상태만 말한다: id · pid를 찍지 않는다
    public var description: String { "ClaudeAgentsItem(state: \(state))" }
    public var debugDescription: String { description }
}

public enum ClaudeAgentsListing {
    /// 답의 상한 = 러너가 표준 출력을 담는 상한(`ClaudeCodeProbe.run`의 64 KiB)과 같다. 더 긴 답은 러너가 정확히 이만큼에서 잘라 온전한 JSON이 아니므로 읽지 않는다 (약 250세션)
    public static let maxBytes = 64 * 1024
    public static let maxItems = 500

    /// 선언한 키만 꺼낸다: 폴더 · 이름 · 종류 · 시작 시각은 디코딩해도 담지 않는다. 틀린 모양의 칸은 없는 것으로 읽는다
    private struct Item: Decodable {
        var pid: Int?
        var sessionId: String?
        var status: String?
        var waitingFor: String?

        enum CodingKeys: String, CodingKey { case pid, sessionId, status, waitingFor }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pid = try? container.decodeIfPresent(Int.self, forKey: .pid)
            sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            waitingFor = try? container.decodeIfPresent(String.self, forKey: .waitingFor)
        }
    }

    /// 항목 하나가 객체가 아니어도 배열 전체가 실패하지 않게
    private struct Lossy: Decodable {
        var item: Item?

        init(from decoder: Decoder) throws {
            item = try? Item(from: decoder)
        }
    }

    /// 최상위가 배열일 때만. 항목이 모양이 틀리면(pid · id가 없거나 틀림, 객체가 아님) 그 항목만 건너뛴다. `status`가 없으면 그 항목의 상태는 unknown
    public static func parse(_ data: Data) -> [ClaudeAgentsItem]? {
        guard data.count <= maxBytes, let all = try? JSONDecoder().decode([Lossy].self, from: data) else { return nil }
        var items: [ClaudeAgentsItem] = []
        for entry in all {
            guard let item = entry.item, let pid = item.pid, pid > 0, pid <= Int(Int32.max), let id = item.sessionId, ExternalSessionRules.isCanonicalUUID(id) else { continue }
            items.append(ClaudeAgentsItem(pid: Int32(pid), sessionID: id, state: ClaudeAppSessionState.parse(status: item.status, waitingFor: item.waitingFor)))
            if items.count == maxItems { break }
        }
        return items
    }
}

/// `claude agents --json` 한 번 (고정 찾기 · 자식 환경 넷 · 기한). 결과는 값 목록뿐이고 로그에는 고정 결과 코드(`ok` · `unavailable`) 하나만 남긴다
public struct ClaudeAgentsLister: Sendable {
    /// 기한 (이 값의 두 배가 B 원천의 캐시 나이 상한에 들어간다: `ClaudeAppStatusPoller`)
    public static let defaultTimeout: TimeInterval = 5

    let locator: ClaudeCodeLocator
    let runner: ClaudeCommandRunner
    let timeout: TimeInterval
    let log: any BridgeLogSink

    /// - runner: 짧은 명령 실행기. 실제 앱은 `live(locator:environment:)`
    public init(locator: ClaudeCodeLocator, runner: @escaping ClaudeCommandRunner, timeout: TimeInterval = ClaudeAgentsLister.defaultTimeout, log: any BridgeLogSink = NoBridgeLog()) {
        self.locator = locator
        self.runner = runner
        self.timeout = timeout
        self.log = log
    }

    /// 실제 앱용: `ClaudeCodeProbe.liveRunner`(자식 환경 넷 · 기한 · 표준 출력 64 KiB)에 cwd는 **비어 있는 임시 폴더**다 (사용자의 폴더 · 프로젝트 설정이 이 명령에 보이지 않는다)
    public static func live(
        locator: ClaudeCodeLocator, environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = defaultTimeout, log: any BridgeLogSink = NoBridgeLog()
    ) -> ClaudeAgentsLister {
        let folder = EmptyFolder()
        return ClaudeAgentsLister(locator: locator, runner: ClaudeCodeProbe.liveRunner(environment: environment, cwd: { folder.path }), timeout: timeout, log: log)
    }

    /// 쓰기 전에 만드는 빈 임시 폴더 (0700). 이 값을 쥔 러너가 사라지면 지운다
    private final class EmptyFolder: @unchecked Sendable {
        private let lock = NSLock()
        private var created: String?

        var path: String {
            lock.withLock {
                if let created, FileManager.default.fileExists(atPath: created) { return created }
                let path = NSTemporaryDirectory() + "tf-claude-agents-" + UUID().uuidString.lowercased()
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                created = path
                return path
            }
        }

        deinit {
            if let created { try? FileManager.default.removeItem(atPath: created) }
        }
    }

    /// 읽지 못하면 nil (`claude`가 없다 · 0이 아닌 종료 · 시간 초과 · 모르는 모양).
    /// 인자는 정확히 `agents --json --setting-sources ""`다: 사용자 · 프로젝트 · 로컬 설정(훅 등)을 읽지 않는다 (`claude agents --help`: `--setting-sources`)
    public func list() async -> [ClaudeAgentsItem]? {
        guard let executable = locator.locate(), let output = await runner(executable, ["agents", "--json", "--setting-sources", ""], timeout), output.exitCode == 0,
              let items = ClaudeAgentsListing.parse(output.stdout) else {
            log.log("claude_app_agents", ["result": .code("unavailable")])
            return nil
        }
        log.log("claude_app_agents", ["result": .code("ok")])
        return items
    }
}
#endif
