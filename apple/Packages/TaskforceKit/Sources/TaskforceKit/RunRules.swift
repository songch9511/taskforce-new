import Foundation

// 실행 화면 규칙 (U2 Mac 계획 PR2). 화면 없는 순수 함수라 표 테스트로 고정한다.
// 무엇이 사실인지(상태 · 결과 · 크레딧)는 서버가 정하고, 여기서는 받은 값을 갈래 · 버튼 · 폴링으로 옮기기만 한다.

extension RunSummary {
    /// 할 일마다 최신 run (만든 시각이 늦은 것, 같으면 id로 정해 읽을 때마다 같게)
    public static func latestByAction(_ runs: [RunSummary]) -> [UUID: RunSummary] {
        var latest: [UUID: RunSummary] = [:]
        for run in runs {
            if let current = latest[run.actionID], !run.isNewer(than: current) { continue }
            latest[run.actionID] = run
        }
        return latest
    }

    func isNewer(than other: RunSummary) -> Bool {
        (createdAt, id.uuidString) > (other.createdAt, other.id.uuidString)
    }
}

/// 상세의 Taskforce 갈래 (Figma M1 Lane · Taskforce 181:1642 · M12 · M17, iPhone P2 · P9).
/// 할 일의 최신 run 하나로 상태를 정하고, 초안은 상태와 따로 둔다: 멈춤 · 실패 · needs_* run에도 앞서 만든 초안이 있을 수 있어
/// (docs/EXECUTION.md 13장, A39) 초안이 있으면 어느 상태든 `View Draft`를 보인다.
public struct RunLane: Equatable, Sendable {
    public enum FailureKind: Equatable, Sendable {
        /// 처리 도중 외부 AI 동의를 철회함
        case consent
        /// AI 공급자가 확정적으로 거절함
        case rejected
        /// 다시 준비 한도를 넘음
        case retriesExhausted
        /// 할 일이 지워짐
        case actionMissing
        /// 모르는 까닭 · 까닭 없음
        case other

        init(_ error: String?) {
            switch error {
            case "consent": self = .consent
            case "rejected": self = .rejected
            case "retries_exhausted": self = .retriesExhausted
            case "action_missing": self = .actionMissing
            default: self = .other
            }
        }
    }

    public enum State: Equatable, Sendable {
        /// run이 없음 (갈래를 보이지 않는다)
        case none
        /// 진행 중 (계획 · 초안 단계를 돈다)
        case working
        /// 끝나지 않았는데 실행기가 막힘 (`hold_reason`). credit은 지급하면 이어 간다
        case paused(RunHoldReason)
        /// 초안이 있음
        case draftReady
        /// Taskforce가 물을 것이 있음. 질문이 90일 정리로 지워졌으면 nil
        case needsInput(question: String?)
        /// 보내려면 연결이 필요함 (초안은 그대로, A39)
        case needsConnection(capability: String?)
        /// 멈춤. 부르던 단계가 남아 결과를 받는 중이면 `finishing`. `stoppedAt`은 서버 값(어느 기기에서 멈췄든, 그 전 서버면 nil)
        case stopped(finishing: Bool, stoppedAt: Date?)
        case failed(FailureKind)
        /// 초안 없이 끝남 (계획 단계가 할 일이 없다고 정함)
        case finishedWithoutDraft
    }

    public let state: State
    /// 이 할 일의 초안 (최근 것이 위). 상태와 상관없이 있으면 `View Draft`
    public let drafts: [Artifact]
    /// 상태를 정한 run (할 일의 최신 run)
    public let run: RunSummary?

    public init(state: State, drafts: [Artifact], run: RunSummary?) {
        self.state = state
        self.drafts = drafts
        self.run = run
    }

    /// `run`: 할 일의 최신 run, `steps`: 그 run의 단계, `artifacts`: 그 할 일의 초안 (모든 run)
    public static func state(run: RunSummary?, steps: [StepSummary], artifacts: [Artifact]) -> RunLane {
        let drafts = artifacts
            .filter { run == nil || $0.actionID == run?.actionID }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        return RunLane(state: resolve(run: run, steps: steps, hasDrafts: !drafts.isEmpty), drafts: drafts, run: run)
    }

    static func resolve(run: RunSummary?, steps: [StepSummary], hasDrafts: Bool) -> State {
        guard let run else { return .none }
        let steps = steps.filter { $0.runID == run.id }.sorted { $0.seq < $1.seq }
        switch run.state {
        case .queued, .running, .waitingApproval:
            if let hold = run.holdReason { return .paused(hold) }
            return .working
        case .done:
            switch run.outcome {
            case .needsInput?:
                return .needsInput(question: lastPlanReceipt(steps, decision: .askUser)?.question.flatMap(nonEmpty))
            case .needsConnection?:
                return .needsConnection(capability: lastPlanReceipt(steps, decision: .needsConnection)?.capability.flatMap(nonEmpty))
            case .draftReady?:
                return .draftReady
            case .unknown?, nil:
                return hasDrafts ? .draftReady : .finishedWithoutDraft
            }
        case .failed:
            let failed = steps.last { $0.state == .failed }
            return .failed(FailureKind(failed?.receipt?.error))
        case .stopped:
            return .stopped(finishing: steps.contains { $0.state == .calling }, stoppedAt: run.stoppedAt)
        case .unknown:
            return hasDrafts ? .draftReady : .none
        }
    }

    private static func lastPlanReceipt(_ steps: [StepSummary], decision: StepDecision) -> StepReceipt? {
        steps.last { $0.kind == .plan && $0.receipt?.decision == decision }?.receipt
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 갈래를 보일지 (보일 상태나 초안이 있을 때만: 모르는 상태 · 초안 없음이면 숨김)
    public var isVisible: Bool { state != .none || !drafts.isEmpty }
}

/// 실행을 시작하는 기기. iPhone은 시작하지 않는다 (사용자 결정 O6: 결과 보기 · 멈추기만)
public enum RunPlatform: Sendable, Hashable {
    case macOS
    case iOS

    #if os(iOS)
    public static let current = RunPlatform.iOS
    #else
    public static let current = RunPlatform.macOS
    #endif
}

/// `Run with AI…`(M8 · ⌘K · ⌘R)를 보일지 · 켤지.
/// 실행 UI는 `GET /credits`가 200일 때만 보인다 (서버는 플래그 꺼짐 · 실행 주체 밖을 404로 숨긴다).
public enum RunAvailability: Equatable, Sendable {
    /// 보이지 않음 (credits 404 · 아직 모름 · iPhone)
    case hidden
    /// 보이지만 꺼짐
    case disabled(Reason)
    case available

    public enum Reason: Equatable, Sendable {
        case signedOut
        case offline
        /// 목록 새로고침이 실패함 (보이는 목록이 서버와 다를 수 있다)
        case refreshFailed
        /// 전체 스위치가 닫힘 (`accepting_runs == false`)
        case notAccepting
        /// 이 할 일에 끝나지 않은 run이 있음
        case alreadyRunning
    }

    /// 이 기기가 run을 시작할 수 있나. iPhone은 언제나 false (`APIClient.createRun`을 iOS 화면이 부르지 않는다)
    public static func canStart(_ platform: RunPlatform) -> Bool {
        platform == .macOS
    }

    /// `credits`: 마지막으로 받은 credits (nil = 404 · 아직 모름), `hasOpenRun`: 이 할 일에 끝나지 않은 run이 있음
    public static func evaluate(
        platform: RunPlatform, credits: CreditsSummary?, signedIn: Bool, refresh: RefreshState, hasOpenRun: Bool
    ) -> RunAvailability {
        guard canStart(platform), let credits else { return .hidden }
        guard signedIn else { return .disabled(.signedOut) }
        if refresh.isOffline { return .disabled(.offline) }
        if case .refreshFailed = refresh { return .disabled(.refreshFailed) }
        if !credits.acceptingRuns { return .disabled(.notAccepting) }
        if hasOpenRun { return .disabled(.alreadyRunning) }
        return .available
    }

    public var isVisible: Bool { self != .hidden }
    public var isEnabled: Bool { self == .available }
}

/// run 상태를 다시 읽는 간격. 보이는 할 일에 아직 움직이는 run(`isBusy`)이 있을 때만 읽는다.
/// 처음 30초는 3초마다(계획 단계가 금방 끝난다), 그 뒤 10초마다. 막힌 run뿐이면 60초마다:
/// 서버가 막힌 run을 5분마다만 깨운다 (`limits.ts` `HELD_WAKE_EVERY_MINUTES`).
/// `actions` Realtime 신호(초안 receipt가 Action을 바꾼다)도 다시 읽는 계기다 (`ActionChanges`).
public enum RunPolling {
    public static let fastInterval: Duration = .seconds(3)
    public static let fastPeriod: TimeInterval = 30
    public static let slowInterval: Duration = .seconds(10)
    public static let heldInterval: Duration = .seconds(60)

    /// 아직 움직이는 run: 끝나지 않았거나, 멈췄는데 부르던 단계가 남아 결과를 받는 중 (`RunLane.State.stopped(finishing: true)`)
    public static func isBusy(_ run: RunSummary, steps: [StepSummary]) -> Bool {
        run.isOpen || (run.state.isFinished && steps.contains { $0.runID == run.id && $0.state == .calling })
    }

    /// `busyRuns`: 보이는 할 일의 움직이는 run (`isBusy`), `watchingSince`: 지켜보기 시작한 때(보이기 시작 · 시작 · 멈춤). 읽지 않으면 nil
    public static func interval(busyRuns: [RunSummary], watchingSince: Date, now: Date) -> Duration? {
        guard !busyRuns.isEmpty else { return nil }
        if busyRuns.allSatisfy({ $0.isOpen && $0.holdReason != nil }) { return heldInterval }
        return now.timeIntervalSince(watchingSince) < fastPeriod ? fastInterval : slowInterval
    }

    /// 지난번에 움직이던 run 중 이번에 멈춘 것 (끝남 · 부르던 단계도 끝남): `/now`(바뀜 점은 서버 값) · credits를 다시 읽는다
    public static func finished(before: Set<UUID>, after: Set<UUID>) -> Set<UUID> {
        before.subtracting(after)
    }
}

/// `Stop Taskforce`(⌘. · ⌘K · iPhone `···`)와 할 일 Delete · Done 전에 멈출 run.
/// 그 할 일의 끝나지 않은 run 전부: 다른 기기 · 웹에서 시작한 run이 겹쳐도 모두 멈춘다.
/// 앱에서 할 일을 지우거나 끝내면 먼저 멈춘다 (목록에서 사라진 할 일이 크레딧을 쓰지 않게, 서버도 열린 Action에서만 다음 단계를 돈다).
public enum RunStop {
    public static func targets(actionID: UUID, runs: [RunSummary]) -> [UUID] {
        runs.filter { $0.actionID == actionID && $0.isOpen }
            .sorted { $0.isNewer(than: $1) }
            .map(\.id)
    }
}

/// 초안 receipt 링크 `taskforce://artifacts/<uuid>` (docs/EXECUTION.md 9장 표). 원문 슬립 · 알림이 이 링크를 연다.
public enum ArtifactLink {
    public static let scheme = "taskforce"
    public static let host = "artifacts"
    /// 읽어서 없을 때 (다른 계정 · 지워진 행). 문구 후보
    public static let notFoundMessage = "Draft not found."

    public static func parse(_ url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: parts[0])
    }

    public static func url(for id: UUID) -> URL {
        URL(string: "\(scheme)://\(host)/\(id.lowercased)")!
    }
}
