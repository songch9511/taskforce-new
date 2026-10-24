#if os(macOS)
import Foundation
import Observation

/// 기록 읽기의 면 (`ClaudeAppTranscriptReader`가 그대로 따른다): 대화 상태는 이 면만 안다. 시험은 줄줄이 정해 둔 답을 주는 가짜를 쓴다
public protocol ClaudeAppTranscriptSource: Sendable {
    func open(sessionID: String, cwd: String?) -> ClaudeAppTranscriptLoad
    func earlier(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptLoad
    func newer(_ cursor: ClaudeAppTranscriptCursor) -> ClaudeAppTranscriptUpdate
    /// 펼친 도구 줄의 입력 · 결과 (읽지 못하는 면은 nil)
    func detail(of turn: ClaudeAppTurn, cursor: ClaudeAppTranscriptCursor) -> ClaudeAppToolDetail?
    /// 세션 폴더의 하위 에이전트 메타 훑기 (부모 · 깊이 · 이름). `since`는 앞서 본 폴더의 바뀐 시각: 그대로면 `.unchanged`. 읽지 못하는 면은 폴더 없음
    func subagents(sessionID: String, cwd: String?, since: SubagentCursor?) -> SubagentListing
}

extension ClaudeAppTranscriptSource {
    public func detail(of turn: ClaudeAppTurn, cursor: ClaudeAppTranscriptCursor) -> ClaudeAppToolDetail? { nil }
    public func subagents(sessionID: String, cwd: String?, since: SubagentCursor?) -> SubagentListing { .missing }
}

extension ClaudeAppTranscriptReader: ClaudeAppTranscriptSource {}

/// Claude 데스크톱 세션 보기(읽기 전용)의 대화 상태 (OA PR-D2, 계약 21.3 P4 · P5 · 21.4). 사용자가 연 그 세션 하나의 기록을, 패널이 열려 있는 동안만, 메모리에만 둔다 (디스크 캐시 0 · 로그 0).
/// - 처음 열면 꼬리부터 마지막 `pageTurns`개(`ClaudeAppTranscriptReader`), "Show earlier"로 앞쪽, 열려 있는 동안 1초마다 새로 붙은 줄(라이브 꼬리)
/// - 못 읽으면 `failed`("Couldn't load this chat" + Try again). 파일이 줄었거나 바뀌었으면(`reset`) 꼬리부터 다시 연다
/// - **파일 읽기는 메인 밖에서** 한다. 읽기는 한 번에 하나씩 차례로 한다 (꼬리 · 앞쪽이 같은 커서를 동시에 만지지 않는다)
/// - **빈 쪽에 `hasEarlier`가 true여도 끝이 아니다** (D1 규칙): 한 번 누르는 안에서 건너뛴 줄뿐인 창을 `maxEmptyWindowsPerPress`개까지 넘어가고, 그래도 끝이 아니면 다시 누르게 한다
/// - `description`은 글 · id 없이 말한다
@MainActor
@Observable
public final class ClaudeAppConversation: CustomStringConvertible, CustomDebugStringConvertible {
    public enum Phase: Equatable, Sendable {
        /// 처음 읽는 중 (그리지 않는다)
        case loading
        case ready
        /// 읽지 못했다 ("Couldn't load this chat" + Try again)
        case failed
    }

    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// 라이브 꼬리의 간격 (계약 21.4 DR-13: 기록은 메시지 블록이 끝날 때마다 붙는다)
    public static let tailInterval: TimeInterval = 1
    /// "Show earlier" 한 번에, 건너뛴 줄뿐이라 빈 쪽인 창을 이만큼까지 넘어간다
    public static let maxEmptyWindowsPerPress = 16
    /// 메모리에 두는 줄의 상한 (보안 P3-4): 라이브 꼬리가 길게 이어져도 줄 수가 이를 넘지 않는다 (넘치면 오래된 줄부터 버리고 Show earlier로 다시 읽을 수 있게 한다).
    /// "Show earlier"로 사용자가 앞을 넓힌 것은 읽기 총량 상한(16 MiB)이 막고, 다음 라이브 줄에서 같은 상한으로 다시 맞춘다
    public static let maxTurns = 1000
    /// 실패한 도구 id를 기억하는 수 (읽은 줄이 아직 오지 않은 앞 쪽의 도구에도 나중에 붙이려고). 넘으면 오래된 것부터 버린다
    public static let maxRememberedFailures = 2048

    public private(set) var phase: Phase = .loading
    /// 오래된 것이 먼저
    public private(set) var turns: [ClaudeAppTurn] = []
    /// "Show earlier"를 보일 수 있다
    public private(set) var hasEarlier = false
    /// 앞쪽을 읽는 중이다 (단추가 한 번에 하나만 돈다)
    public private(set) var loadingEarlier = false
    /// 이 세션이 돌리는 백그라운드 일 · 하위 에이전트 (기록의 시작 · 끝 줄 + `subagents/` 메타의 부모 · 깊이 · 이름). 트리는 `SubagentTree`가 이것으로 만든다
    public private(set) var backgroundTasks = BackgroundTaskList()
    /// 보는 쪽이 맨 아래에 붙어 있다 (패널의 스크롤 위치가 알린다). 위로 거슬러 읽는 중이면 false: 그동안은 라이브 줄이 붙어도 위쪽 줄을 버리지 않는다 (읽던 글이 사라지거나 밀리지 않게).
    /// 맨 아래로 돌아오면 그때 상한에 맞춘다. 상한의 두 배를 넘으면 붙어 있지 않아도 버린다 (메모리 상한)
    public var pinnedToBottom = true {
        didSet { if pinnedToBottom, !oldValue { trimToLimit() } }
    }

    public let sessionID: String
    @ObservationIgnored private let cwd: String?
    @ObservationIgnored private let source: any ClaudeAppTranscriptSource
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let turnLimit: Int
    @ObservationIgnored private var cursor: ClaudeAppTranscriptCursor?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 읽기를 한 번에 하나씩 잇는 사슬
    @ObservationIgnored private var chain: Task<Void, Never>?
    /// 다시 열 때마다 오른다: 그 전에 시작한 읽기의 늦은 결과를 버린다
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shownIDs = Set<String>()
    /// 오류로 끝난 도구 호출의 id (오래된 것이 먼저): 아직 읽지 않은 앞 쪽의 도구 줄에도 나중에 붙이려고 기억한다. 상한 `maxRememberedFailures`
    @ObservationIgnored private var failedIDs: [String] = []
    @ObservationIgnored private var failedSet = Set<String>()
    @ObservationIgnored private var unpairedOutcomes: [String: AgentCallRecord.Outcome] = [:]
    @ObservationIgnored private var unpairedOutcomeOrder: [String] = []
    /// 도구 호출 id → 모델이 쓴 description (백그라운드 일의 이름을 찾는다): 줄이 상한에서 버려져도 남는다. 상한 `maxRememberedDescriptions`
    @ObservationIgnored private var toolDescriptions: [String: String] = [:]
    @ObservationIgnored private var toolDescriptionOrder: [String] = []
    static let maxRememberedDescriptions = 4096
    /// 기록의 시작 · 끝 줄만으로 만든 일 목록: 상태는 이것이 정한다. 화면에 내는 `backgroundTasks`는 여기에 메타를 겹친 것이다
    @ObservationIgnored private var signalTasks = BackgroundTaskList()
    /// 마지막으로 읽은 `subagents/` 메타 (폴더가 그대로면 다시 읽지 않는다) · 그때의 자리(프로젝트 폴더 · 폴더의 바뀐 시각)
    @ObservationIgnored private var subagentMetas: [SubagentMeta] = []
    @ObservationIgnored private var subagentCursor: SubagentCursor?
    /// 본 기록에서 본 에이전트 도구 호출과 그 결과 (도구 호출 id → 짝): 깊이 1 전경 에이전트의 상태를 메타의 `toolUseId`와 짝지어 정한다. 오래된 것부터 버린다 (상한 `maxRememberedAgentCalls`)
    @ObservationIgnored private var agentCalls: [String: AgentCallRecord] = [:]
    @ObservationIgnored private var agentCallOrder: [String] = []
    static let maxRememberedAgentCalls = 2048
    /// 하위 에이전트 폴더가 없는 채로 지나간 꼬리 읽기 수: 없는 폴더를 매초 찾아다니지 않는다 (새 줄이 오면 바로, 아니면 `missingScanEvery`번에 한 번)
    @ObservationIgnored private var quietTicks = 0
    static let missingScanEvery = 5

    /// 읽기 한 번 뒤에 무엇을 하나
    private enum Step: Sendable {
        /// 이어 간다 (꼬리: 잠들었다 다시)
        case next
        /// 남은 것이 있다: 기다리지 않고 바로 이어 읽는다
        case again
        /// 멈춘다 (못 읽었거나 낡은 읽기)
        case stop
    }

    /// - cwd: 등록 파일의 작업 폴더 (기록의 프로젝트 디렉터리를 바로 짐작한다)
    /// - turnLimit: 메모리에 두는 줄의 상한 (기본 `maxTurns`, 시험은 작게)
    public init(
        sessionID: String, cwd: String?, source: any ClaudeAppTranscriptSource, turnLimit: Int = ClaudeAppConversation.maxTurns,
        sleep: @escaping Sleep = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.source = source
        self.turnLimit = max(1, turnLimit)
        self.sleep = sleep
    }

    // MARK: 시작 · 멈춤

    /// 열려 있는 동안의 읽기를 시작한다: 처음이면 꼬리부터 열고, 이미 읽은 것이 있으면 이어서 꼬리를 따라간다. 이미 돌고 있으면 아무 일도 없다
    public func start() {
        guard loop == nil else { return }
        let started = generation
        let needsOpen = cursor == nil
        let sleep = sleep
        loop = Task { [weak self] in
            if needsOpen, await self?.runOpen(generation: started) != .next { return }
            while !Task.isCancelled {
                var step = Step.again
                while step == .again, !Task.isCancelled { step = await self?.tail(generation: started) ?? .stop }
                guard step == .next else { return }
                await sleep(Self.tailInterval)
                guard self != nil else { return }
            }
        }
    }

    /// 패널이 닫혔다: 꼬리를 멈춘다 (읽은 것은 남는다: 다시 열면 이어서 따라간다)
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Try again: 처음부터 다시 읽는다
    public func retry() {
        stop()
        generation += 1
        phase = .loading
        turns = []
        hasEarlier = false
        loadingEarlier = false
        cursor = nil
        shownIDs = []
        forgetSignals()
        start()
    }

    // MARK: 읽기 (한 번에 하나씩)

    /// 한 읽기를 앞 읽기가 끝난 뒤에 돌리고 그 값을 돌려준다
    private func serial<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) async -> T {
        let previous = chain
        let task = Task<T, Never> { @MainActor in
            await previous?.value
            return await body()
        }
        chain = Task { _ = await task.value }
        return await task.value
    }

    /// 읽은 기록의 꼬리를 한 쪽 읽는다 (`Task.detached`: 메인 밖)
    private nonisolated static func openAsync(_ source: any ClaudeAppTranscriptSource, _ sessionID: String, _ cwd: String?) async -> ClaudeAppTranscriptLoad {
        await Task.detached(priority: .userInitiated) { source.open(sessionID: sessionID, cwd: cwd) }.value
    }

    /// 처음 열기. 꼬리를 이어 가도 되면 `.next`
    private func runOpen(generation started: Int) async -> Step {
        await serial { [self] in
            guard started == generation else { return .stop }
            let load = await Self.openAsync(source, sessionID, cwd)
            guard started == generation else { return .stop }
            switch load {
            case .page(let page):
                cursor = page.cursor
                replace(with: page.turns)
                settle(fresh: page.turns, signals: page.cursor.signals)
                hasEarlier = page.hasEarlier
                phase = .ready
                await scanSubagents(generation: started)
                return .next
            case .unreadable:
                phase = .failed
                return .stop
            }
        }
    }

    /// 꼬리 한 번: 못 읽으면 `failed`로 끝내고 멈춘다. 남은 것이 있으면 `.again`
    private func tail(generation started: Int) async -> Step {
        await serial { [self] in
            guard started == generation, let current = cursor else { return .stop }
            let source = source
            let update = await Task.detached(priority: .userInitiated) { source.newer(current) }.value
            guard started == generation else { return .stop }
            switch update {
            case .turns(let more, let next, let hasMore):
                cursor = next
                append(more)
                settle(fresh: more, signals: next.signals)
                // 꼬리를 읽었다: 앞서 못 읽어 `failed`였어도 다시 읽히는 대화다
                phase = .ready
                if shouldScanSubagents(sawActivity: !more.isEmpty || !next.signals.isEmpty) { await scanSubagents(generation: started) }
                return hasMore ? .again : .next
            case .reset:
                // 파일이 줄었거나 바뀌었다: 꼬리부터 다시 연다 (옛 파일의 실패 · 일 목록은 버린다)
                let load = await Self.openAsync(source, sessionID, cwd)
                guard started == generation else { return .stop }
                guard case .page(let page) = load else {
                    phase = .failed
                    return .stop
                }
                cursor = page.cursor
                replace(with: page.turns)
                forgetSignals()
                settle(fresh: page.turns, signals: page.cursor.signals)
                hasEarlier = page.hasEarlier
                phase = .ready
                await scanSubagents(generation: started)
                return .next
            case .unreadable:
                phase = .failed
                return .stop
            }
        }
    }

    /// "Show earlier": 앞쪽 창 하나를 읽어 앞에 붙인다. 한 번에 하나만 돈다. 읽을 것이 없으면 아무 일도 없다.
    /// 건너뛴 줄뿐이라 빈 쪽인데 더 앞이 있으면(끝이 아니다) 한 번 누른 안에서 `maxEmptyWindowsPerPress`개까지 넘어간다
    public func showEarlier() {
        guard hasEarlier, !loadingEarlier, phase == .ready else { return }
        loadingEarlier = true
        let started = generation
        Task { [weak self] in
            await self?.runEarlier(generation: started)
        }
    }

    private func runEarlier(generation started: Int) async {
        await serial { [self] in
            defer { if started == generation { loadingEarlier = false } }
            var empties = 0
            while started == generation, let current = cursor, hasEarlier {
                let source = source
                let load = await Task.detached(priority: .userInitiated) { source.earlier(current) }.value
                guard started == generation else { return }
                guard case .page(let page) = load else {
                    phase = .failed
                    return
                }
                cursor = page.cursor
                hasEarlier = page.hasEarlier
                prepend(page.turns)
                settle(fresh: page.turns, signals: page.cursor.signals)
                // 건너뛴 줄뿐이라 빈 쪽이다: 끝이 아니면 한 번 누른 안에서 더 앞으로 간다 (한도까지)
                guard Self.visible(page.turns).isEmpty, page.hasEarlier else { return }
                empties += 1
                if empties >= Self.maxEmptyWindowsPerPress { return }
            }
        }
    }

    // MARK: 반영

    /// 글 없는 경계(교환을 끝내는 표시, OA PR-D3 검토 P2-1)는 화면의 대화에 나오지 않는다
    private static func visible(_ turns: [ClaudeAppTurn]) -> [ClaudeAppTurn] { turns.filter { $0.kind != .boundary } }

    private func replace(with all: [ClaudeAppTurn]) {
        let fresh = Self.visible(all)
        turns = fresh
        shownIDs = Set(fresh.map(\.id))
    }

    private func append(_ more: [ClaudeAppTurn]) {
        let fresh = Self.visible(more).filter { shownIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        turns += fresh
        trimToLimit()
    }

    /// 줄 수가 상한을 넘으면 오래된 줄부터 버린다 (보안 P3-4). 버린 앞은 "Show earlier"가 다시 읽을 수 있어야 한다:
    /// 버린 줄의 id는 지금 보이는 것에서 빼고 (다시 읽혀도 중복으로 걸러지지 않게), 커서의 가장 앞 자리를 남은 가장 앞 줄의 자리로 옮겨 구멍이 없게 하며
    /// (버린 줄의 몫은 읽기 총량에서 돌려받는다), `hasEarlier`를 올린다. 기록 안의 자리를 모르는 줄(견본)이면 커서는 그대로다
    private func trimToLimit() {
        // 위로 거슬러 읽는 중에는 상한의 두 배까지 둔다
        guard pinnedToBottom || turns.count > turnLimit * 2 else { return }
        let excess = turns.count - turnLimit
        guard excess > 0 else { return }
        for turn in turns.prefix(excess) { shownIDs.remove(turn.id) }
        turns.removeFirst(excess)
        hasEarlier = true
        if var current = cursor, let first = turns.first, first.lineOffset > current.earliestOffset {
            current.coveredBytes = max(0, current.coveredBytes - Int(first.lineOffset - current.earliestOffset))
            current.earliestOffset = first.lineOffset
            cursor = current
        }
    }

    private func prepend(_ older: [ClaudeAppTurn]) {
        let fresh = Self.visible(older).filter { shownIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        turns = fresh + turns
    }

    // MARK: 신호 (실패한 도구 · 백그라운드 일)

    /// 다시 읽는다 (Try again · 파일이 바뀌었다): 옛 읽기의 실패 · 도구 설명 · 일 목록을 버린다
    private func forgetSignals() {
        failedIDs = []
        failedSet = []
        unpairedOutcomes = [:]
        unpairedOutcomeOrder = []
        toolDescriptions = [:]
        toolDescriptionOrder = []
        signalTasks = BackgroundTaskList()
        subagentMetas = []
        subagentCursor = nil
        agentCalls = [:]
        agentCallOrder = []
        quietTicks = 0
        backgroundTasks = BackgroundTaskList()
    }

    /// 이번 꼬리 읽기에서 하위 에이전트 폴더를 훑을까: 폴더가 있었으면 늘(속에서 에이전트가 자란다), 없었으면 새 줄이 왔을 때 또는 몇 번에 한 번
    private func shouldScanSubagents(sawActivity: Bool) -> Bool {
        if subagentCursor != nil || sawActivity {
            quietTicks = 0
            return true
        }
        quietTicks += 1
        return quietTicks.isMultiple(of: Self.missingScanEvery)
    }

    /// 세션 폴더의 하위 에이전트 메타를 훑어 일 목록에 겹친다 (파일 읽기는 메인 밖에서). 폴더가 그대로면 아무것도 읽지 않고, 없어졌거나 믿을 수 없게 되면 메타를 비운다 (믿을 수 없는 폴더의 값은 남기지 않는다)
    private func scanSubagents(generation started: Int) async {
        let source = source
        let session = sessionID
        let folder = cwd
        let since = subagentCursor
        let listing = await Task.detached(priority: .userInitiated) { source.subagents(sessionID: session, cwd: folder, since: since) }.value
        guard started == generation else { return }
        switch listing {
        case .metas(let found, let cursor):
            subagentMetas = found
            subagentCursor = cursor
        case .unchanged:
            return
        case .missing, .unreadable:
            subagentMetas = []
            subagentCursor = nil
        }
        publishTasks()
    }

    /// 화면에 내는 목록 = 기록의 시작 · 끝 줄로 만든 목록 + 메타 (달라졌을 때만 바꾼다)
    private func publishTasks() {
        var calls = agentCalls
        // Outcomes can precede call lines outside the read window. Keep these
        // separately bounded, so unrelated tools never evict known Agent calls.
        for meta in subagentMetas {
            guard let id = meta.toolUseID, let outcome = unpairedOutcomes[id], calls[id]?.outcome == nil else { continue }
            var record = calls[id] ?? AgentCallRecord()
            record.outcome = outcome
            calls[id] = record
        }
        let combined = signalTasks.adding(subagents: subagentMetas, calls: calls)
        if combined != backgroundTasks { backgroundTasks = combined }
    }

    /// 에이전트 호출(`Agent` · 예전 이름 `Task`의 도구 줄) 또는 그 결과를 장부에 적는다 (같은 id는 한 칸으로 합친다)
    private func noteAgentCall(_ id: String, _ update: (inout AgentCallRecord) -> Void) {
        if agentCalls[id] == nil {
            agentCallOrder.append(id)
            if agentCallOrder.count > Self.maxRememberedAgentCalls {
                let dropped = agentCallOrder.removeFirst()
                agentCalls[dropped] = nil
            }
        }
        update(&agentCalls[id, default: AgentCallRecord()])
    }

    /// 읽은 한 번(`fresh`: 새로 들어온 줄 · `signals`)을 반영한다: 도구 설명을 배우고, 실패 id를 기억하고, 일 사건을 먹이고, 이름을 찾고, 실패를 도구 줄에 붙인다
    private func settle(fresh: [ClaudeAppTurn], signals: ClaudeAppTranscriptSignals) {
        for turn in fresh {
            guard case .tool(_, let description?) = turn.kind, !description.isEmpty, let id = turn.toolUseID, toolDescriptions[id] == nil else { continue }
            toolDescriptions[id] = description
            toolDescriptionOrder.append(id)
        }
        if toolDescriptionOrder.count > Self.maxRememberedDescriptions {
            let excess = toolDescriptionOrder.count - Self.maxRememberedDescriptions
            for id in toolDescriptionOrder.prefix(excess) { toolDescriptions[id] = nil }
            toolDescriptionOrder.removeFirst(excess)
        }
        for turn in fresh {
            guard case .tool(let name, _) = turn.kind, name == "Agent" || name == "Task", let id = turn.toolUseID, BackgroundTaskText.isValidToolUseID(id) else { continue }
            noteAgentCall(id) { record in
                record.called = true
                if record.startedAt == nil { record.startedAt = turn.timestamp }
            }
        }
        for outcome in signals.toolOutcomes where agentCalls[outcome.toolUseID]?.called == true {
            noteAgentCall(outcome.toolUseID) { $0.outcome = AgentCallRecord.Outcome(failed: outcome.failed, at: outcome.at) }
        }
        for outcome in signals.toolOutcomes where agentCalls[outcome.toolUseID]?.called != true {
            if unpairedOutcomes[outcome.toolUseID] == nil { unpairedOutcomeOrder.append(outcome.toolUseID) }
            unpairedOutcomes[outcome.toolUseID] = AgentCallRecord.Outcome(failed: outcome.failed, at: outcome.at)
        }
        if unpairedOutcomeOrder.count > Self.maxRememberedAgentCalls {
            let excess = unpairedOutcomeOrder.count - Self.maxRememberedAgentCalls
            for id in unpairedOutcomeOrder.prefix(excess) { unpairedOutcomes[id] = nil }
            unpairedOutcomeOrder.removeFirst(excess)
        }
        for id in signals.failedToolIDs where failedSet.insert(id).inserted { failedIDs.append(id) }
        if failedIDs.count > Self.maxRememberedFailures {
            let excess = failedIDs.count - Self.maxRememberedFailures
            for id in failedIDs.prefix(excess) { failedSet.remove(id) }
            failedIDs.removeFirst(excess)
        }
        var list = signalTasks
        for event in signals.background { list.apply(event) }
        list.resolveNames { toolDescriptions[$0] }
        signalTasks = list
        publishTasks()
        if !failedSet.isEmpty {
            let indices = turns.indices.filter { index in
                guard case .tool = turns[index].kind, !turns[index].failed, let id = turns[index].toolUseID else { return false }
                return failedSet.contains(id)
            }
            for index in indices { turns[index].failed = true }
        }
    }

    public var rememberedFailureCount: Int { failedIDs.count }

    /// 펼친 도구 줄의 본문 (입력 · 결과): 읽기는 메인 밖에서 한다. 도구 줄이 아니거나 아직 읽기 전이면 nil (읽지 못하는 면은 늘 nil)
    public func detail(of turn: ClaudeAppTurn) async -> ClaudeAppToolDetail? {
        guard case .tool = turn.kind, let current = cursor else { return nil }
        let source = source
        return await Task.detached(priority: .userInitiated) { source.detail(of: turn, cursor: current) }.value
    }

    /// 글 · id를 찍지 않는다
    public nonisolated var description: String { "ClaudeAppConversation()" }
    public nonisolated var debugDescription: String { description }
}
#endif
