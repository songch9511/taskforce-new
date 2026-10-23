#if os(macOS)
import Foundation

/// 기록의 `subagents/agent-<id>.meta.json`에서 읽은 하위 에이전트 한 개 (에이전트 트리 T1). **선언한 칸 넷만** 읽는다: `parentAgentId` · `spawnDepth` · `description` · `requestShape`.
/// 모르는 칸(`finished` · `toolUseId` · `worktreePath` · …)은 선언하지 않아 값으로 남지 않는다. 깨진 파일은 그 파일만 버린다. id는 파일 이름에서 오고 파일 안의 글로 바꾸지 않는다.
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

    public init(id: String, parentID: String?, depth: Int?, name: String?, requestShape: String?) {
        self.id = id
        self.parentID = parentID
        self.depth = depth
        self.name = name
        self.requestShape = requestShape
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

        enum CodingKeys: String, CodingKey { case parentAgentID = "parentAgentId", spawnDepth, description, requestShape }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            parentAgentID = try? container.decodeIfPresent(String.self, forKey: .parentAgentID)
            spawnDepth = try? container.decodeIfPresent(Int.self, forKey: .spawnDepth)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            requestShape = try? container.decodeIfPresent(String.self, forKey: .requestShape)
        }
    }

    /// 파일 내용(최대 `maxBytes`) → 값. 깨졌거나 JSON 객체가 아니거나 크면 nil
    static func parse(_ data: Data, id: String) -> SubagentMeta? {
        guard BackgroundTaskText.isValidTaskID(id), !data.isEmpty, data.count <= maxBytes, String(validating: data, as: UTF8.self) != nil,
              let declared = try? JSONDecoder().decode(Declared.self, from: data) else { return nil }
        let parent = declared.parentAgentID.flatMap { BackgroundTaskText.isValidTaskID($0) ? $0 : nil }
        let depth = declared.spawnDepth.flatMap { (0...16).contains($0) ? $0 : nil }
        let name = declared.description.flatMap { text in ExternalSessionRules.sanitizedTitle(text.count > maxNameCharacters ? String(text.prefix(maxNameCharacters)) : text) }
        return SubagentMeta(id: id, parentID: parent, depth: depth, name: name, requestShape: declared.requestShape.flatMap(token))
    }

    /// 짧은 표식 낱말: 영숫자와 `_` `.` `:` `-` 1–64자
    private static func token(_ text: String) -> String? {
        guard (1...64).contains(text.utf8.count), text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2E || $0 == 0x3A || $0 == 0x2D }) else { return nil }
        return text
    }
}

/// 세션 폴더의 `subagents/`를 훑은 결과 (`BackgroundTaskTail.subagents`)
public enum SubagentListing: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 읽은 메타 (가장 새 것 먼저, 최대 `SubagentMeta.maxMetas`개). `stamp`는 훑을 때 본 `subagents/` 폴더의 바뀐 시각: 다음에 같은 값을 주면 폴더가 그대로라 이름도 훑지 않는다
    case metas([SubagentMeta], stamp: Date)
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
#endif
