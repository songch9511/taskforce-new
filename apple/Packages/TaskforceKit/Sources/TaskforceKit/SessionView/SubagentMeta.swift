#if os(macOS)
import Foundation

/// 기록의 `subagents/agent-<id>.meta.json`에서 읽은 하위 에이전트 한 개 (에이전트 트리 T1). **선언한 칸 다섯만** 읽는다: `parentAgentId` · `spawnDepth` · `description` · `requestShape` · `toolUseId`.
/// 모르는 칸(`finished` · `worktreePath` · …)은 선언하지 않아 값으로 남지 않는다. 깨진 파일은 그 파일만 버린다. id는 파일 이름에서 오고 파일 안의 글로 바꾸지 않는다.
/// 이름은 모델이 쓴 `description`뿐이다 (프롬프트 · 요약 · 경로 · 명령은 이 값에 없다). `description`(문자열 표현)은 이름 · id를 찍지 않는다
public struct SubagentMeta: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 메타 파일 하나에서 읽는 크기 (이보다 큰 파일은 열지도 않는다)
    public static let maxBytes = 4096
    /// 한 세션 폴더에서 받는 메타 이름의 수 (넘으면 가장 오래된 것부터 무시한다)
    public static let maxMetas = 256
    /// 폴더 이름을 나열하는 상한 (`agent-<id>.jsonl` · `.prefix.json` 짝까지 있으니 메타의 몇 배)
    public static let maxScanned = 2048
    /// 이름(description) 글자 수 상한 (한 줄 이름이면 충분하다)
    static let maxNameCharacters = 400

    public let id: String
    /// provider가 준 부모 에이전트 id (깊이 2 이상일 때만 있다). 없으면 세션 바로 아래이거나 모른다
    public var parentID: String?
    /// `spawnDepth` (0–16 정수). 밖이면 nil
    public var depth: Int?
    /// 모델이 쓴 description (정리한 글). 없으면 nil
    public var name: String?
    /// 요청 모양 표식 (짧은 낱말 하나). 화면 · 상태 판단에 쓰지 않는다
    public var requestShape: String?
    /// 이 에이전트를 띄운 도구 호출의 id (`toolUseId`, 도구 호출 id 규칙). 깊이 1 에이전트의 상태를 본 기록의 도구 결과와 짝지을 때만 쓴다
    public var toolUseID: String?

    public init(id: String, parentID: String?, depth: Int?, name: String?, requestShape: String?, toolUseID: String? = nil) {
        self.id = id
        self.parentID = parentID
        self.depth = depth
        self.name = name
        self.requestShape = requestShape
        self.toolUseID = toolUseID
    }

    public var description: String { "SubagentMeta()" }
    public var debugDescription: String { description }

    /// `agent-<id>.meta.json` 이름에서 id (id는 일 id 규칙 `[A-Za-z0-9_-]{1,64}`). 이름 규칙 밖이면 nil
    static func id(fromFileName name: String) -> String? {
        let prefix = "agent-"
        let suffix = ".meta.json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.utf8.count > prefix.utf8.count + suffix.utf8.count else { return nil }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return BackgroundTaskText.isValidTaskID(id) ? id : nil
    }

    /// 선언한 칸만 담는 해석 모양. 칸마다 따로 거른다 (한 칸이 틀려도 다른 칸은 남는다). 최상위가 객체가 아니면 던진다
    private struct Declared: Decodable {
        var parentAgentID: String?
        var spawnDepth: Int?
        var description: String?
        var requestShape: String?
        var toolUseID: String?

        enum CodingKeys: String, CodingKey { case parentAgentID = "parentAgentId", spawnDepth, description, requestShape, toolUseID = "toolUseId" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            parentAgentID = try? container.decodeIfPresent(String.self, forKey: .parentAgentID)
            spawnDepth = try? container.decodeIfPresent(Int.self, forKey: .spawnDepth)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            requestShape = try? container.decodeIfPresent(String.self, forKey: .requestShape)
            toolUseID = try? container.decodeIfPresent(String.self, forKey: .toolUseID)
        }
    }

    /// 파일 내용(최대 `maxBytes`) → 값. 깨졌거나 JSON 객체가 아니거나 크면 nil
    static func parse(_ data: Data, id: String) -> SubagentMeta? {
        guard BackgroundTaskText.isValidTaskID(id), !data.isEmpty, data.count <= maxBytes, String(validating: data, as: UTF8.self) != nil,
              let declared = try? JSONDecoder().decode(Declared.self, from: data) else { return nil }
        let parent = declared.parentAgentID.flatMap { BackgroundTaskText.isValidTaskID($0) ? $0 : nil }
        let depth = declared.spawnDepth.flatMap { (0...16).contains($0) ? $0 : nil }
        let name = declared.description.flatMap { text in ExternalSessionRules.sanitizedTitle(text.count > maxNameCharacters ? String(text.prefix(maxNameCharacters)) : text) }
        let toolUse = declared.toolUseID.flatMap { BackgroundTaskText.isValidToolUseID($0) ? $0 : nil }
        return SubagentMeta(id: id, parentID: parent, depth: depth, name: name, requestShape: declared.requestShape.flatMap(token), toolUseID: toolUse)
    }

    /// 짧은 표식 낱말: 영숫자와 `_` `.` `:` `-` 1–64자
    private static func token(_ text: String) -> String? {
        guard (1...64).contains(text.utf8.count), text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A || $0 == 0x2D }) else { return nil }
        return text
    }
}

/// 앞서 훑은 자리 (다음 훑기에 그대로 건넨다). 값의 뜻은 읽는 쪽만 안다
public struct SubagentCursor: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 첫 훑기가 찾은 프로젝트 디렉터리 이름: 다음 훑기는 `~/.claude/projects`를 다시 나열하지 않고 이 아래의 길만 다시 확인한다
    let project: String
    /// 그때 본 `subagents/` 폴더의 바뀐 시각: 같으면 이름도 훑지 않는다
    let stamp: Date
    /// 폴더 항목이 `SubagentMeta.maxScanned`개를 넘어 앞의 그만큼만 봤다 (읽는 순서는 정해져 있지 않아 가장 새 에이전트가 빠졌을 수 있다). 화면은 달라지지 않는다
    public let overflowed: Bool

    init(project: String, stamp: Date, overflowed: Bool = false) {
        self.project = project
        self.stamp = stamp
        self.overflowed = overflowed
    }

    public var description: String { "SubagentCursor()" }
    public var debugDescription: String { description }
}

/// 세션 폴더의 `subagents/`를 훑은 결과 (`BackgroundTaskTail.subagents`)
public enum SubagentListing: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 읽은 메타 (가장 새 것 먼저, 최대 `SubagentMeta.maxMetas`개) + 다음 훑기에 건넬 자리
    case metas([SubagentMeta], cursor: SubagentCursor)
    /// 폴더가 `since` 이후 그대로다 (길은 다시 확인했다)
    case unchanged
    /// 그 세션에 하위 에이전트 폴더가 없다 (또는 기록 폴더가 없다)
    case missing
    /// 있는데 믿을 수 없다 (기호 링크 · 남의 것 · 다른 사용자가 쓸 수 있는 폴더 · 세션 id 틀림 · 읽기 실패)
    case unreadable

    public var description: String {
        switch self {
        case .metas: "SubagentListing.metas"
        case .unchanged: "SubagentListing.unchanged"
        case .missing: "SubagentListing.missing"
        case .unreadable: "SubagentListing.unreadable"
        }
    }

    public var debugDescription: String { description }
}

/// 본 기록에서 본 에이전트 도구 호출 하나와 그 결과 (도구 호출 id로 메타의 `toolUseId`와 짝지어진다). 깊이 1 전경 에이전트의 상태를 정한다:
/// 결과가 있으면 끝난 것(`failed`면 Failed, 아니면 Done, 시각은 결과 줄의 시각), 호출만 봤고 결과가 없으면 도는 중, 둘 다 못 봤으면 모른다
public struct AgentCallRecord: Equatable, Sendable {
    public struct Outcome: Equatable, Sendable {
        public var failed: Bool
        public var at: Date?

        public init(failed: Bool, at: Date?) {
            self.failed = failed
            self.at = at
        }
    }

    /// 호출 줄(`tool_use`)을 봤다
    public var called: Bool
    /// 호출 줄의 시각
    public var startedAt: Date?
    public var outcome: Outcome?

    public init(called: Bool = false, startedAt: Date? = nil, outcome: Outcome? = nil) {
        self.called = called
        self.startedAt = startedAt
        self.outcome = outcome
    }
}
#endif
