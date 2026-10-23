#if os(macOS)
import Foundation

// 데스크톱 세션의 대화 읽기가 내는 값 (PR-D1 Kit, 계약 21.4). 이 Mac 안에서만 만들어지고 메모리에만 둔다 (디스크 캐시 0 · 로그 0).
// `description`은 글 · 경로 · id · pid 없이 종류만 말한다. (`dump`는 필드를 그대로 찍는다: 로그에 값을 `dump`하지 않는다.)

/// 다른 Claude 세션이 보낸 메시지의 출처 (`origin.kind == "peer"`, DR-7).
/// **`plugin` 이름만으로 Taskforce 중계라고 믿지 않는다**: 같은 uid의 다른 프로세스도 `tf-relay`라는 이름의 mod로 메시지를 보낼 수 있다.
/// Taskforce가 띄운 중계 프로세스의 pid(받는 쪽이 소켓에서 확인한 `verifiedPeerPid`)까지 같아야 "via Taskforce"다
public struct ClaudeAppPeer: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
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

    /// 이 메시지를 **우리 중계 프로세스(`relayPID`)가** 보냈다: 플러그인 이름이 `tf-relay`이고 검증된 보낸 pid가 `relayPID`와 같다
    public func isTaskforceRelay(relayPID: Int32) -> Bool {
        plugin == Self.taskforceRelayPlugin && verifiedPeerPID == relayPID
    }

    public var description: String { "ClaudeAppPeer()" }
    public var debugDescription: String { description }
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
    /// 도구 줄의 대상: **파일 이름 하나뿐**이다 (`file_path` · `notebook_path`의 마지막 성분. 경로 · 명령 · 검색어는 읽지 않는다). 없으면 nil
    public var target: String?
    /// 도구 결과가 오류였다 (`tool_result.is_error`, 불리언 하나. 오류 글은 읽지 않는다). 결과가 나중에 오면 대화 상태가 이 줄을 고친다
    public var failed: Bool
    var lineOffset: Int64
    var toolUseID: String?

    /// 읽는 쪽이 만든다 (줄 위치 · 도구 id를 담는다)
    init(id: String, kind: Kind, timestamp: Date?, truncated: Bool, lineOffset: Int64, toolUseID: String?, target: String? = nil, failed: Bool = false) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.truncated = truncated
        self.lineOffset = lineOffset
        self.toolUseID = toolUseID
        self.target = target
        self.failed = failed
    }

    /// 견본 · 미리보기용 (실제 기록 위치가 없다: 이 값으로 `detail`을 부르면 nil이다)
    public init(id: String, kind: Kind, timestamp: Date? = nil, truncated: Bool = false, target: String? = nil, failed: Bool = false) {
        self.init(id: id, kind: kind, timestamp: timestamp, truncated: truncated, lineOffset: -1, toolUseID: nil, target: target, failed: failed)
    }

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

/// 한 번 읽은 창에서 나온, 대화 줄이 아닌 사실 둘 (세션 보기 V1, DZ oa-session-view-dz v2): 오류로 끝난 도구 결과의 도구 id · 백그라운드 일의 시작과 끝.
/// **선언한 칸만** 꺼낸다: 불리언 `is_error` · 아이디 · 상태 · 끝낸 코드 · 시각. 오류 글 · 명령 · 출력 · 요약 · 프롬프트는 읽지 않는다. 읽은 그 번의 것이다 (읽을 때마다 새로 채워진다)
public struct ClaudeAppTranscriptSignals: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var failedToolIDs: [String]
    public var background: [BackgroundTaskEvent]

    public init(failedToolIDs: [String] = [], background: [BackgroundTaskEvent] = []) {
        self.failedToolIDs = failedToolIDs
        self.background = background
    }

    public var isEmpty: Bool { failedToolIDs.isEmpty && background.isEmpty }

    /// 아이디를 찍지 않는다
    public var description: String { "ClaudeAppTranscriptSignals()" }
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
    /// 이어 읽을 자리 (완성된 줄의 끝)
    var nextOffset: Int64
    /// 거슬러 간 거리: 열었을 때의 파일 끝 − 가장 앞 줄의 시작. 총량 상한(16 MiB)은 이것으로 센다 (같은 바이트를 다시 읽은 것은 세지 않는다)
    var coveredBytes: Int
    /// 너무 긴 줄의 나머지를 개행까지 버리는 중
    var discarding: Bool
    /// 이미 보여 준 peer 메시지의 열쇠 = (msg_id, 검증된 보낸 pid, 플러그인) (같은 메시지가 `user`와 `queued_command` 두 모양으로 기록되어도 한 번만). 최근 256개
    var peerIDs: [String]
    /// **이 읽기가** 찾은 신호 (실패한 도구 · 백그라운드 일의 사건). 읽을 때마다 새로 채워지고, 읽을 것이 없었던 번은 비어 있다: 대화 상태가 읽자마자 가져간다
    public internal(set) var signals: ClaudeAppTranscriptSignals

    init(
        sessionID: String, path: String, created: Date, earliestOffset: Int64, nextOffset: Int64, coveredBytes: Int, discarding: Bool, peerIDs: [String],
        signals: ClaudeAppTranscriptSignals = ClaudeAppTranscriptSignals()
    ) {
        self.sessionID = sessionID
        self.path = path
        self.created = created
        self.earliestOffset = earliestOffset
        self.nextOffset = nextOffset
        self.coveredBytes = coveredBytes
        self.discarding = discarding
        self.peerIDs = peerIDs
        self.signals = signals
    }

    /// 견본 · 미리보기용: 아무 파일도 가리키지 않는다 (읽기는 못 읽음으로 끝난다)
    public init(sessionID: String) {
        self.init(sessionID: sessionID, path: "", created: .distantPast, earliestOffset: 0, nextOffset: 0, coveredBytes: 0, discarding: false, peerIDs: [])
    }

    public var description: String { "ClaudeAppTranscriptCursor()" }
    public var debugDescription: String { description }
}

public struct ClaudeAppTranscriptPage: Equatable, Sendable {
    /// 오래된 것이 먼저. `earlier`의 쪽은 앞에 붙일 것만 담는다
    public var turns: [ClaudeAppTurn]
    public var cursor: ClaudeAppTranscriptCursor
    /// "Show earlier"를 보일 수 있다. **빈 쪽(`turns`가 비었다)에 `hasEarlier`가 true여도 끝이 아니다**: 한 번에 읽는 창이 건너뛴 줄(너무 큰 줄 · 대화가 아닌 줄)뿐일 수 있다. `hasEarlier`가 false일 때만 끝이다
    public var hasEarlier: Bool
    /// 대화 줄처럼 보였으나 읽지 못했거나 너무 커서 건너뛴 줄의 수
    public var skippedLines: Int

    public init(turns: [ClaudeAppTurn], cursor: ClaudeAppTranscriptCursor, hasEarlier: Bool, skippedLines: Int) {
        self.turns = turns
        self.cursor = cursor
        self.hasEarlier = hasEarlier
        self.skippedLines = skippedLines
    }
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

/// 펼친 도구 줄의 본문. 입력 · 결과 글은 찍지 않는다 (`description`은 글자 수도 말하지 않는다)
public struct ClaudeAppToolDetail: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var input: String
    /// 결과가 아직 기록에 없으면 nil
    public var result: String?
    public var truncated: Bool

    public init(input: String, result: String?, truncated: Bool) {
        self.input = input
        self.result = result
        self.truncated = truncated
    }

    public var description: String { "ClaudeAppToolDetail()" }
    public var debugDescription: String { description }
}
#endif
