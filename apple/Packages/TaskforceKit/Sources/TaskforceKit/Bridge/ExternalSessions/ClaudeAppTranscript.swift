#if os(macOS)
import Foundation

// 데스크톱 세션의 대화 읽기가 내는 값 (PR-D1 Kit, 계약 21.4). 이 Mac 안에서만 만들어지고 메모리에만 둔다 (디스크 캐시 0 · 로그 0).
// `description`은 글 · 경로 · id 없이 종류만 말한다.

/// 다른 Claude 세션이 보낸 메시지의 출처 (`origin.kind == "peer"`, DR-7). Taskforce 중계가 보낸 글은 `isTaskforceRelay`다 ("via Taskforce")
public struct ClaudeAppPeer: Equatable, Sendable {
    /// 계약 DR-S2b의 중계 mod 이름
    public static let taskforceRelayPlugin = "tf-relay"

    public var plugin: String?
    public var verifiedPeerPID: Int32?
    public var messageID: String?

    public init(plugin: String?, verifiedPeerPID: Int32?, messageID: String?) {
        self.plugin = plugin
        self.verifiedPeerPID = verifiedPeerPID
        self.messageID = messageID
    }

    public var isTaskforceRelay: Bool { plugin == Self.taskforceRelayPlugin }
}

/// 대화 한 줄. 도구는 이름과 `description`뿐이다 (본문은 `detail`로 펼칠 때만)
public struct ClaudeAppTurn: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// 데스크톱에서 친 말
        case user(String)
        case assistant(String)
        /// 다른 세션의 메시지: 받은 글(`origin.body`, 받는 쪽이 감싼 글이 아니다)
        case peer(String, ClaudeAppPeer)
        case tool(name: String, description: String?)
    }

    /// 기록 파일 안의 줄 위치 + 그 줄의 몇 번째: 쪽 · 이어 읽기를 넘어도 같은 줄은 같은 id
    public let id: String
    public var kind: Kind
    public var timestamp: Date?
    /// 글이 상한에서 잘렸다
    public var truncated: Bool
    var lineOffset: Int64
    var toolUseID: String?

    public var description: String {
        let name = switch kind {
        case .user: "user"
        case .assistant: "assistant"
        case .peer: "peer"
        case .tool: "tool"
        }
        return "ClaudeAppTurn(\(name))"
    }

    public var debugDescription: String { description }
}

/// 어디까지 읽었나. 경로 · id는 담지만 찍지 않는다
public struct ClaudeAppTranscriptCursor: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sessionID: String
    let path: String
    /// 파일의 만든 시각: 다르면 다른 파일이다 (바뀌어 쓰임)
    var created: Date
    /// 지금까지 읽은 가장 앞 줄의 시작 (0이면 처음까지)
    var earliestOffset: Int64
    /// 그 앞은 한 줄의 가운데다 (너무 긴 줄을 건너뛰었다): 다음 이전 쪽은 마지막 개행 뒤를 버린다
    var earliestMidLine: Bool
    /// 이어 읽을 자리 (완성된 줄의 끝)
    var nextOffset: Int64
    /// 처음 열기 · 이전 쪽으로 읽은 총량
    var bytesRead: Int
    /// 너무 긴 줄의 나머지를 개행까지 버리는 중
    var discarding: Bool

    public var description: String { "ClaudeAppTranscriptCursor()" }
    public var debugDescription: String { description }
}

public struct ClaudeAppTranscriptPage: Equatable, Sendable {
    /// 오래된 것이 먼저. `earlier`의 쪽은 앞에 붙일 것만 담는다
    public var turns: [ClaudeAppTurn]
    public var cursor: ClaudeAppTranscriptCursor
    /// "Show earlier"를 보일 수 있다
    public var hasEarlier: Bool
    /// 대화 줄처럼 보였으나 읽지 못했거나 너무 커서 건너뛴 줄의 수
    public var skippedLines: Int
}

public enum ClaudeAppTranscriptLoad: Equatable, Sendable {
    case page(ClaudeAppTranscriptPage)
    /// 기록을 찾지 못했거나 열 수 없다 ("Couldn't load this chat")
    case unreadable
}

public enum ClaudeAppTranscriptUpdate: Equatable, Sendable {
    case turns([ClaudeAppTurn], cursor: ClaudeAppTranscriptCursor, hasMore: Bool)
    /// 파일이 줄었거나 바뀌었다: `open`부터 다시
    case reset
    case unreadable
}

/// 펼친 도구 줄의 본문
public struct ClaudeAppToolDetail: Equatable, Sendable {
    public var input: String
    /// 결과가 아직 기록에 없으면 nil
    public var result: String?
    public var truncated: Bool
}

#endif
