#if os(macOS)
import Foundation

/// 서버에 올릴 행 하나 (PR-D3k, 계약 25.1 · 26장). 글 · 도구 **이름**만이다: 경로 · 도구 입력 · 결과 · 폴더 이름 · Claude 세션 id · pid · 모드는 어느 칸에도 없다.
/// `description`은 글 없이 종류만 말한다
public struct ClaudeAppChatRow: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Role: String, Equatable, Sendable { case user, assistant }

    /// Mac 열쇠 HMAC (소문자 hex 64자): 같은 줄은 늘 같은 값이라 두 번 올려도 한 행이다 (DT15)
    public var macRef: String
    public var role: Role
    /// 답 행이 가리키는 사용자 행의 `macRef`
    public var replyToRef: String?
    public var body: String
    public var truncated: Bool
    public var saidAt: Date
    /// 이 답 글 **앞에서** 쓴 도구 단계의 이름 (순서 유지, 최대 40, 이름 모양 `^[A-Za-z0-9_-]{1,128}$`만)
    public var toolNames: [String]

    public init(macRef: String, role: Role, replyToRef: String?, body: String, truncated: Bool, saidAt: Date, toolNames: [String]) {
        self.macRef = macRef
        self.role = role
        self.replyToRef = replyToRef
        self.body = body
        self.truncated = truncated
        self.saidAt = saidAt
        self.toolNames = toolNames
    }

    public var description: String { "ClaudeAppChatRow(\(role.rawValue))" }
    public var debugDescription: String { description }
}

/// 교환이 끝난 까닭 (계약 25.1 ①–⑤)
public enum ClaudeAppExchangeEnd: Equatable, Sendable {
    /// ① 데스크톱에서 친 말(`origin` 없는 `user` 줄)
    case desktopUserLine
    /// ② 다음 peer 줄 (누가 보냈든)
    case nextPeer
    /// ③ L 뒤 `busy → idle`을 보았고 기록을 끝까지 읽었다
    case turnEnded
    /// ④ L 뒤 30분
    case timeout
    /// ⑤ 한 교환에 답 글 64 KiB 또는 블록 40개
    case limit
}

public struct ClaudeAppExchange: Equatable, Sendable {
    /// 사용자 행이 먼저, 답 행이 기록 순서로. L을 아직 못 찾았으면 비어 있다
    public var rows: [ClaudeAppChatRow]
    /// 끝났으면 그 까닭 (더 따라가지 않는다)
    public var finished: ClaudeAppExchangeEnd?
    /// 찾은 L의 줄 id (없으면 아직 기록에 안 나왔다)
    public var matchedTurnID: String?

    public init(rows: [ClaudeAppChatRow], finished: ClaudeAppExchangeEnd?, matchedTurnID: String?) {
        self.rows = rows
        self.finished = finished
        self.matchedTurnID = matchedTurnID
    }
}

public struct ClaudeAppExchangeInput: Sendable {
    public var sessionID: String
    /// 지금까지 읽은 줄 (오래된 것이 먼저)
    public var turns: [ClaudeAppTurn]
    /// 우리 중계 프로세스의 pid (peer 줄의 `verifiedPeerPid`와 같아야 우리 것이다)
    public var relayPID: Int32
    /// 보낸 글 그대로 (L의 `origin.body`와 바이트까지 같아야 한다)
    public var sentText: String
    public var sentAt: Date
    public var now: Date
    /// ③: L 뒤 `busy → idle`을 보았고 기록을 끝까지 읽었다 (부르는 쪽이 안다)
    public var turnEnded: Bool
    /// 보내기 **전에** 이미 기록에 있던 줄의 id: 같은 글을 이전에 보낸 줄을 이번 것으로 착각하지 않는다
    public var baseline: Set<String>
    /// 씨앗 글 → 불투명 ref (실제 앱은 Mac 열쇠 HMAC, 시험은 가짜). 씨앗은 세션 · 줄 id뿐이고 글은 들어가지 않는다
    public var ref: @Sendable (String) -> String

    public init(
        sessionID: String, turns: [ClaudeAppTurn], relayPID: Int32, sentText: String, sentAt: Date, now: Date, turnEnded: Bool, baseline: Set<String>, ref: @escaping @Sendable (String) -> String
    ) {
        self.sessionID = sessionID
        self.turns = turns
        self.relayPID = relayPID
        self.sentText = sentText
        self.sentAt = sentAt
        self.now = now
        self.turnEnded = turnEnded
        self.baseline = baseline
        self.ref = ref
    }
}

/// 저장할 행을 고르는 순수 함수 (PR-D3k, 계약 25.1 · 26장 · 위협 DT11 · DT15)
public enum ClaudeAppExchangeCollector {
    /// 한 교환에 담는 답 글의 상한 (본문 바이트 합)
    public static let maxAnswerBytes = 65_536
    /// 한 교환에 담는 답 글 블록 수
    public static let maxAnswerBlocks = 40
    /// 한 답 글 앞에 붙이는 도구 이름 수
    public static let maxToolNames = 40
    /// L 뒤 이 시간이 지나면 끝난다
    public static let followWindow: TimeInterval = 30 * 60

    public static func collect(_ input: ClaudeAppExchangeInput) -> ClaudeAppExchange {
        // L: 우리 중계가 보낸 그 글 (이번 보내기 전에 있던 줄은 제외)
        guard let start = input.turns.firstIndex(where: { isOurLine($0, input) }), case .peer(_, let peer) = input.turns[start].kind else {
            return ClaudeAppExchange(rows: [], finished: nil, matchedTurnID: nil)
        }
        let line = input.turns[start]
        let lineTime = line.timestamp ?? input.sentAt
        let userRef = input.ref("user\n\(input.sessionID)\n\(peer.messageID ?? line.id)\n\(input.relayPID)")
        // 사용자 행의 글은 보낸 글 그대로다 (읽기가 32 KiB에서 자른 글이 아니다)
        var rows = [ClaudeAppChatRow(macRef: userRef, role: .user, replyToRef: nil, body: input.sentText, truncated: false, saidAt: lineTime, toolNames: [])]
        var finished: ClaudeAppExchangeEnd?
        var used = 0
        var blocks = 0
        var pendingTools: [String] = []
        var lastTime = lineTime

        walk: for turn in input.turns[(start + 1)...] {
            if let time = turn.timestamp, time.timeIntervalSince(lineTime) >= followWindow {
                finished = .timeout
                break walk
            }
            switch turn.kind {
            case .user:
                finished = .desktopUserLine
                break walk
            case .peer:
                finished = .nextPeer
                break walk
            case .tool(let name, _):
                // 이름만: 설명 · 입력 · 결과는 읽지 않는다. 서버가 받는 모양이 아닌 이름은 그 이름 하나만 버린다
                if isToolName(name), pendingTools.count < maxToolNames { pendingTools.append(name) }
            case .assistant(let text):
                let cleaned = sanitized(text)
                guard !cleaned.allSatisfy(\.isWhitespace) else { continue }
                let remaining = maxAnswerBytes - used
                let fits = cleaned.utf8.count <= remaining
                let body = fits ? cleaned : prefix(cleaned, utf8Bytes: remaining)
                guard !body.isEmpty else {
                    finished = .limit
                    break walk
                }
                used += body.utf8.count
                blocks += 1
                let time = turn.timestamp ?? lastTime
                lastTime = time
                rows.append(
                    ClaudeAppChatRow(
                        macRef: input.ref("assistant\n\(input.sessionID)\n\(turn.id)"), role: .assistant, replyToRef: userRef, body: body, truncated: turn.truncated || !fits, saidAt: time, toolNames: pendingTools
                    )
                )
                pendingTools = []
                // 잘렸으면(예산이 모자랐다) 거기서 끝난다: 남은 한두 바이트에 다음 블록의 앞글자를 붙이지 않는다
                if !fits || used >= maxAnswerBytes || blocks >= maxAnswerBlocks {
                    finished = .limit
                    break walk
                }
            }
        }
        if finished == nil {
            if input.turnEnded {
                finished = .turnEnded
            } else if input.now.timeIntervalSince(lineTime) >= followWindow {
                finished = .timeout
            }
        }
        return ClaudeAppExchange(rows: rows, finished: finished, matchedTurnID: line.id)
    }

    /// 우리 중계가 보낸 그 글: peer 줄, 플러그인 `tf-relay`, 검증된 보낸 pid가 우리 중계, 글이 보낸 글과 바이트까지 같다, 이번 보내기 전부터 있던 줄이 아니다.
    /// 읽기가 글 한 칸을 32 KiB에서 자른 줄(`truncated`)은 보낸 글의 앞부분이면 같은 글이다 (긴 글이 "Not received"가 되지 않게)
    private static func isOurLine(_ turn: ClaudeAppTurn, _ input: ClaudeAppExchangeInput) -> Bool {
        guard !input.baseline.contains(turn.id), case .peer(let text, let peer) = turn.kind, peer.isTaskforceRelay(relayPID: input.relayPID) else { return false }
        return text == input.sentText || (turn.truncated && !text.isEmpty && input.sentText.hasPrefix(text))
    }

    /// 서버가 받는 도구 이름: `^[A-Za-z0-9_-]{1,128}$`
    static func isToolName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }
    }

    /// 제어 글자를 지운다 (개행 · 탭은 둔다): 서버는 NUL을 거절하고, JSON 이스케이프(`\u00XX`)가 요청 크기 상한을 먹지 않게
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A: true
            case 0x00...0x1F, 0x7F...0x9F: false
            default: true
            }
        }))
    }

    /// UTF-8로 `limit` 바이트 안에서 글자(유니코드 스칼라) 경계로 자른다
    static func prefix(_ text: String, utf8Bytes limit: Int) -> String {
        var used = 0
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            guard used + size <= limit else { break }
            used += size
            out.append(scalar)
        }
        return String(out)
    }
}
#endif
