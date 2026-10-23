#if os(macOS)
import Foundation

/// 데스크톱 세션으로 보낸 말 하나의 전달 상태 기계 (PR-D3k, 계약 25.4.4 · DZ 승인 2026-10-22 시트 4). **순수하다**: 시계는 사건마다 `at:`으로 받고(주입), 기록 · 프로세스 · 중계는 만지지 않는다.
///
/// 상태: Sending… → Sent(중계가 넘김) → Received · via Taskforce(대상 기록에서 우리 줄을 찾음). 대상이 질문을 기다리면 Queued · {이유}이고 **30초 시계가 멈춘다**.
/// 못 보내면 Not sent · {닫힘 · 받지 못함 · Bypass · 두 곳}. 30초는 중계가 넘긴(Sent) 때부터 센다: 그동안 질문이 떠 있던 시간은 세지 않는다.
/// 끝난 상태(Received · Not sent)는 늦게 온 사건으로 되돌아가지 않는다. 확인 전(`isPending`) 글은 세션마다 하나다 (DR-S2c ④)
public struct ClaudeAppDeliveryTracker: Equatable, Sendable {
    /// 중계가 넘긴 뒤 기록에서 줄을 기다리는 시간 (DR-S2d)
    public static let confirmationWindow: TimeInterval = 30

    public enum State: Equatable, Sendable {
        case sending
        case sent
        /// 대상이 질문(권한 · 물음)을 기다리는 동안: 같은 턴에서 읽힌다
        case queued(ClaudeAppWait)
        case received
        case notSent(ClaudeAppNotSentReason)

        /// 화면의 전달 줄: 승인된 문구만 (아이콘 · 색 없음, 빨강 없음)
        public var line: MessageDeliveryLine {
            switch self {
            case .sending: MessageDeliveryLine(strong: nil, text: ClaudeAppChatCopy.sending)
            case .sent: MessageDeliveryLine(strong: nil, text: ClaudeAppChatCopy.sent)
            case .queued(.approval): MessageDeliveryLine(strong: nil, text: "\(AgentCopy.queued) · \(ClaudeAppCopy.needsApproval)")
            case .queued(.answer): MessageDeliveryLine(strong: nil, text: "\(AgentCopy.queued) · \(ClaudeAppCopy.needsAnswer)")
            case .received: MessageDeliveryLine(strong: nil, text: ClaudeAppChatCopy.receivedViaTaskforce)
            case .notSent(let reason):
                MessageDeliveryLine(
                    strong: ClaudeAppChatCopy.notSent, text: reason.words, link: reason.allowsSendAgain ? MessageDeliveryLine.Link(.sendAgain, ClaudeAppChatCopy.sendAgain) : nil
                )
            }
        }
    }

    public enum Event: Equatable, Sendable {
        /// mod가 `isDelivered true`를 돌려줬다 (대상 소켓에 넣었다)
        case relayAccepted
        /// 중계가 보내지 못했다 (`isDelivered false`: 닫힌 세션 · 받지 않음, 또는 중계 실패)
        case relayRefused(ClaudeAppNotSentReason)
        /// 대상의 지금 상태 (등록 파일 · agents-json). `nil`이면 모른다
        case target(ClaudeAppSessionState?)
        /// 대상 프로세스가 끝났다
        case targetClosed
        /// 대상 기록에서 우리 줄을 찾았다 (DR-S2d의 네 조건)
        case transcriptReceived
        /// 시계가 갔다: 기록이 말하는 대상의 권한 모드(`permissionMode`, 모르면 nil)를 함께 준다
        case tick(permissionMode: String?)
        /// 보내기 전 확인이 막았다 (보내지 않았다)
        case blocked(ClaudeAppNotSentReason)
    }

    public private(set) var state: State = .sending
    public let startedAt: Date
    /// 중계가 넘긴 시각 (30초 시계의 시작)
    private var sentAt: Date?
    /// 질문 때문에 시계가 멈춰 있던 시간의 합
    private var pausedTotal: TimeInterval = 0
    /// 지금 Queued로 들어간 시각
    private var pausedSince: Date?

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// 아직 끝나지 않았다 (확인 전): 다음 글을 막는다
    public var isPending: Bool {
        switch state {
        case .sending, .sent, .queued: true
        case .received, .notSent: false
        }
    }

    public mutating func apply(_ event: Event, at now: Date) {
        guard isPending else { return }
        switch event {
        case .relayAccepted:
            guard state == .sending else { return }
            state = .sent
            sentAt = now
        case .relayRefused(let reason), .blocked(let reason):
            guard state == .sending else { return }
            state = .notSent(reason)
        case .transcriptReceived:
            state = .received
        case .targetClosed:
            state = .notSent(.sessionClosed)
        case .target(let observed):
            observe(observed, at: now)
        case .tick(let mode):
            guard state == .sent, let sentAt else { return }
            let spent = now.timeIntervalSince(sentAt) - pausedTotal
            if spent >= Self.confirmationWindow {
                state = .notSent(mode == Self.bypassMode ? .bypass : .notReceived)
            }
        }
    }

    /// 기록의 `permissionMode`가 Bypass를 말하는 값
    static let bypassMode = "bypassPermissions"

    private mutating func observe(_ observed: ClaudeAppSessionState?, at now: Date) {
        switch state {
        case .sent, .queued: break
        case .sending, .received, .notSent: return
        }
        if case .waiting(let wait)? = observed {
            if pausedSince == nil { pausedSince = now }
            state = .queued(wait)
        } else if let since = pausedSince {
            pausedTotal += max(0, now.timeIntervalSince(since))
            pausedSince = nil
            state = .sent
        }
    }
}
#endif
