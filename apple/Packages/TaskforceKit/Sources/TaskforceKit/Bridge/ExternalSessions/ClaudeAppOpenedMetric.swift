#if os(macOS)
import Foundation
import Observation

/// 데스크톱 세션 보기를 연 날의 지표 (OA PR-D2, 계약 21.6): `claude_app_session_opened`. **종류만이다** — 어떤 세션인지 · 제목 · 폴더는 보내지 않는다 (`POST /api/v2/external-sessions/claude-app-opened`, 본문은 빈 객체).
/// UTC 날짜마다 한 번, 서버에 닿았을 때만 그날을 적는다 (서버도 하루 한 번으로 거른다: 앱을 다시 켜서 또 보내도 조용히 넘긴다). 닿지 못하면 `retryInterval` 뒤 다음에 열 때 다시.
/// 계정이 떠나면 잊고, 그 사이 돌던 보내기의 늦은 답은 새 계정의 날을 적지 않는다. 로그는 실패 코드 하나뿐이다 (값 0)
@MainActor
@Observable
public final class ClaudeAppOpenedMetric {
    /// 서버에 닿지 못했을 때 다시 보내기까지의 간격
    public static let retryInterval: TimeInterval = 60

    /// 서버에 닿은 마지막 UTC 날 (1970-01-01부터 센 일 수). 없으면 아직
    public private(set) var lastSentDay: Int?
    public private(set) var isSending = false

    @ObservationIgnored private let send: @Sendable () async -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let log: any BridgeLogSink
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var generation = 0

    /// - send: 서버에 알린다. 서버에 닿았으면(같은 날 두 번째라 조용히 넘긴 것도) true
    public init(send: @escaping @Sendable () async -> Bool, scope: AccountScope? = nil, now: @escaping @Sendable () -> Date = { Date() }, log: any BridgeLogSink = NoBridgeLog()) {
        self.send = send
        self.now = now
        self.log = log
        scope?.onLeft { [weak self] in self?.reset() }
    }

    /// 사용자가 데스크톱 세션 보기를 열었다 (링 · Sessions의 줄을 눌렀다). 오늘 이미 닿았거나 보내는 중이면 아무 일도 없다
    public func opened() {
        let current = now()
        let day = Int((current.timeIntervalSince1970 / 86_400).rounded(.down))
        guard lastSentDay != day, !isSending else { return }
        if let lastAttempt, current.timeIntervalSince(lastAttempt) < Self.retryInterval { return }
        isSending = true
        lastAttempt = current
        let started = generation
        let send = send
        Task { [weak self] in
            let reached = await send()
            guard let self, started == generation else { return }
            isSending = false
            if reached {
                lastSentDay = day
            } else {
                log.log("claude_app_opened_failed", [:])
            }
        }
    }

    private func reset() {
        generation += 1
        lastSentDay = nil
        isSending = false
        lastAttempt = nil
    }
}
#endif
