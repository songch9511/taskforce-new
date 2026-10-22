#if os(macOS)
import Foundation
import Observation

/// 레일 · Sessions 패널이 읽는 Claude 데스크톱 세션의 살아 있는 상태 (OA PR-D2, 계약 21.2 DR-S1a · 23장).
/// - **폴은 1초마다 차례로 부른다** (`ClaudeAppStatusPoller.poll()`: 이전 폴이 돌아온 뒤에 다음 폴, 겹치지 않는다). 읽는 값은 단조 시간(`uptime`)과 벽시계(`now`) 둘이다
/// - 레일 판정은 `ClaudeAppRail`에 기억을 이어 준다. **끝난 것(done)은 사용자가 열어 볼 때까지 남는다** (`markOpened` · `setViewing`): 표시는 `ClaudeAppDoneStore`에 저장해 다시 켠 뒤에도 남는다
/// - 지금 사용자가 보고 있는 세션(`setViewing`)은 끝나도 done이 되지 않는다
/// - 계정이 떠나면 비우고 저장해 둔 표시도 지운다 (늦은 폴의 결과는 버린다)
/// - 제목은 여기 없다: 부르는 쪽이 `ExternalSessionsStore`의 줄에서 같은 Claude 세션 id로 찾아 붙인다
/// - 값은 이 Mac 안에서만 쓴다. `description`은 개수만 말한다 (id · pid · 폴더 0)
@MainActor
@Observable
public final class ClaudeAppSessionsModel: CustomStringConvertible, CustomDebugStringConvertible {
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// 레일이 있는 동안 폴하는 간격 (DR-S1a)
    public static let pollInterval: TimeInterval = 1

    /// 지금 살아 있고 믿는 데스크톱 세션들 (id 순, 상태 포함: 쉬는 세션도 있다)
    public private(set) var sessions: [ClaudeAppSession] = []
    /// 레일에 오를 수 있는 것 (needs-you → running → done)
    public private(set) var rail: [ClaudeAppRailEntry] = []
    /// 살아 있는 등록이 둘 이상인 id (믿지 않는다)
    public private(set) var doubled: Set<String> = []
    /// 첫 폴이 끝났다 (그 전에는 "아직 모른다"이지 "세션이 없다"가 아니다)
    public private(set) var hasPolled = false
    /// 마지막 폴에서 등록 폴더를 읽을 수 없었다
    public private(set) var registryUnavailable = false
    /// 보고 있는 세션(`setViewing`)의 프로세스가 끝났다 ("Closed in Claude"): 연달아 `ClaudeAppRail.missingGrace + 1`번 안 보였을 때만 (한두 번은 읽기가 흔들린 것이다).
    /// 등록 폴더를 읽을 수 없는 폴은 세지 않는다 (모르는 것이지 끝난 것이 아니다)
    public private(set) var viewingClosed = false

    @ObservationIgnored private let poll: @Sendable () async -> ClaudeAppStatusPoller.Poll
    @ObservationIgnored private var viewingAbsent = 0
    @ObservationIgnored private let done: any ClaudeAppDoneStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var memory: ClaudeAppRailMemory
    /// 마지막으로 저장한 표시 (바뀔 때만 쓴다)
    @ObservationIgnored private var savedMarks: [String: ClaudeAppDoneMark]
    @ObservationIgnored private var viewing: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 계정이 떠날 때마다 오른다: 그 전에 시작한 폴의 늦은 결과를 버린다
    @ObservationIgnored private var generation = 0
    /// `stop()`마다 오른다: 루프가 멈추기 전에 시작한 폴의 늦은 결과를 버린다
    @ObservationIgnored private var loopToken = 0
    @ObservationIgnored private let scope: AccountScope?
    /// 표시의 주인으로 확정한 계정 (`adopt`)
    @ObservationIgnored private var adoptedOwner: UUID?

    /// - poll: `ClaudeAppStatusPoller.poll()` (시험은 가짜). 한 번에 하나씩 차례로 부른다
    /// - done: 안 연 끝남 표시를 두는 곳. 저장해 둔 표시가 있으면 그 프로세스가 아직 살아 쉬고 있을 때 첫 폴에서 done으로 다시 오른다
    public init(
        poll: @escaping @Sendable () async -> ClaudeAppStatusPoller.Poll, scope: AccountScope? = nil, done: any ClaudeAppDoneStore = InMemoryClaudeAppDoneStore(),
        now: @escaping @Sendable () -> Date = { Date() }, uptime: @escaping @Sendable () -> TimeInterval = { ClaudeAppMonotonic.now() },
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.poll = poll
        self.scope = scope
        self.done = done
        self.now = now
        self.uptime = uptime
        self.sleep = sleep
        let restored = ClaudeAppRailMemory(restoring: done.load())
        memory = restored
        savedMarks = restored.doneMarks
        scope?.onLeft { [weak self] in self?.reset() }
    }

    public func session(id: String) -> ClaudeAppSession? {
        sessions.first { $0.id == id }
    }

    // MARK: 폴 루프

    /// 1초마다 차례로 폴한다. 이미 돌고 있으면 아무 일도 없다. 모델이 사라지면 루프도 끝난다 (루프가 모델을 붙잡지 않는다)
    public func start() {
        guard loop == nil else { return }
        let sleep = sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                await sleep(Self.pollInterval)
                guard self != nil else { return }
            }
        }
    }

    /// 루프를 멈춘다. 그 전에 시작해 돌고 있던 폴의 늦은 결과는 반영하지 않는다
    public func stop() {
        loop?.cancel()
        loop = nil
        loopToken += 1
    }

    /// 한 번 폴해 반영한다 (루프가 부른다. 시험 · 시작 직후에도). 폴이 도는 사이 계정이 떠났거나 루프가 멈췄으면 그 결과를 버린다
    public func pollOnce() async {
        let started = generation
        let token = loopToken
        let result = await poll()
        guard started == generation, token == loopToken else { return }
        // 계정을 알게 됐으면 저장해 둔 표시가 이 계정의 것인지 가린 뒤에 판정한다 (첫 폴이 다른 계정의 표시를 되살리지 않게)
        if let account = scope?.token?.userID { adopt(account: account) }
        apply(result)
    }

    private func apply(_ poll: ClaudeAppStatusPoller.Poll) {
        // 등록 폴더를 읽을 수 없는 폴은 "세션이 없다"가 아니라 "모른다"다: 판정하지 않고 기억(`memory`)과 저장해 둔 표시를 그대로 둔다.
        // (판정하면 모든 세션이 안 보이는 것이 되어 기다리는 폴 수(`missingGrace`)가 지나면 끝남 표시가 지워진다.) 레일에는 아무것도 그리지 않는다
        if poll.registryUnavailable {
            sessions = []
            doubled = []
            registryUnavailable = true
            rail = []
            hasPolled = true
            return
        }
        let result = ClaudeAppRail.evaluate(sessions: poll.sessions, memory: memory, now: now(), uptime: uptime(), opened: viewing.map { [$0] } ?? [])
        memory = result.memory
        sessions = poll.sessions
        doubled = poll.doubled
        registryUnavailable = false
        rail = result.entries
        hasPolled = true
        if let id = viewing {
            viewingAbsent = poll.sessions.contains { $0.id == id } ? 0 : viewingAbsent + 1
        }
        viewingClosed = viewing != nil && viewingAbsent > ClaudeAppRail.missingGrace
        saveIfChanged()
    }

    // MARK: 표시의 주인 계정 (보안 P3-1)

    /// 이 계정을 표시의 주인으로 확정한다 (셸이 로그인을 알 때 · 첫 폴 때): 저장해 둔 표시의 주인이 이 계정이 아니면(다른 계정이거나 모르면) 이 계정의 것이 아니라서 기억 · 저장본을 모두 비운다.
    /// 같은 계정을 다시 알려도 아무 일도 없다
    public func adopt(account: UUID) {
        guard adoptedOwner != account else { return }
        adoptedOwner = account
        if done.owner != account {
            memory = ClaudeAppRailMemory()
            savedMarks = [:]
            rail.removeAll { $0.kind == .done }
            done.clear()
        }
        done.setOwner(account)
    }

    // MARK: 열어 봄

    /// 사용자가 이 세션을 열었다 (레일의 링 · Sessions의 줄): 끝남 표시를 지우고 그 자리에서 레일을 고친다 (다음 폴을 기다리지 않는다). 같은 완료는 다시 오르지 않고 새 턴이 끝나야 다시 done이다.
    /// done이 없거나 모르는 세션이면 아무 일도 없다
    public func markOpened(_ id: String) {
        guard var track = memory.tracks[id], track.done != nil else { return }
        track.done = nil
        memory.tracks[id] = track.activeSeen != nil ? track : nil
        rail.removeAll { $0.id == id && $0.kind == .done }
        saveIfChanged()
    }

    /// 지금 사용자가 보고 있는 세션 (패널이 열려 있는 동안, 닫으면 nil): 그 세션이 끝나도 done이 되지 않고, 이미 done이면 연 것이다
    public func setViewing(_ id: String?) {
        if id != viewing {
            viewingAbsent = 0
            viewingClosed = false
        }
        viewing = id
        if let id { markOpened(id) }
    }

    private func saveIfChanged() {
        let marks = memory.doneMarks
        guard marks != savedMarks else { return }
        savedMarks = marks
        done.save(marks)
    }

    /// 계정이 떠남: 비우고 저장해 둔 표시도 지운다 (다른 계정에 남지 않는다). 폴이 도는 중이면 그 결과는 버린다
    private func reset() {
        generation += 1
        adoptedOwner = nil
        memory = ClaudeAppRailMemory()
        savedMarks = [:]
        viewing = nil
        viewingAbsent = 0
        viewingClosed = false
        sessions = []
        rail = []
        doubled = []
        hasPolled = false
        registryUnavailable = false
        done.clear()
    }

    /// 개수만 말한다: 세션 id · pid를 찍지 않는다
    public nonisolated var description: String { "ClaudeAppSessionsModel()" }
    public nonisolated var debugDescription: String { description }
}
#endif
