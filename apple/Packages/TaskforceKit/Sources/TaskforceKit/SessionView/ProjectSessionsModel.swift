#if os(macOS)
import Foundation
import Observation

@MainActor
@Observable
public final class ProjectSessionsModel {
    public private(set) var boardVersion = 0
    private var expanded: Set<UUID> = []
    private var all: Set<UUID> = []
    private var snapshots: [UUID: BackgroundTaskList] = [:]
    private var expansions: [UUID: SubagentTreeExpansion] = [:]
    @ObservationIgnored private var lastRead: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var board = BackgroundTaskBoard()
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private var metrics: AgentTreeMetrics?
    @ObservationIgnored private var findTarget: (@MainActor (UUID) async -> AgentLocalTranscriptTarget?)?
    @ObservationIgnored private var makeSource: (@Sendable (String, String?) -> any ClaudeAppTranscriptSource)?

    public init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, metrics: AgentTreeMetrics? = nil) {
        self.uptime = uptime
        self.metrics = metrics
    }

    public func connect(board: BackgroundTaskBoard, findTarget: @escaping @MainActor (UUID) async -> AgentLocalTranscriptTarget?, makeSource: @escaping @Sendable (String, String?) -> any ClaudeAppTranscriptSource) {
        self.board = board
        self.findTarget = findTarget
        self.makeSource = makeSource
        syncBoard()
    }
    public func setMetrics(_ metrics: AgentTreeMetrics?) { self.metrics = metrics }
    public func canExpand(_ session: AgentSessionItem) -> Bool { session.agent == .claudeCode }
    public func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }
    public func showsAll(_ id: UUID) -> Bool { all.contains(id) }
    public func toggleShowAll(_ id: UUID) { if !all.insert(id).inserted { all.remove(id) } }
    public func syncBoard() { if boardVersion != board.version { boardVersion = board.version } }
    public func tasks(of session: AgentSessionItem) -> BackgroundTaskList {
        let live = board.tasks(session: session.id.uuidString)
        let list = live.merged(with: snapshots[session.id] ?? BackgroundTaskList())
        return session.isClosed ? list.closed(at: session.updatedAt) : list
    }
    public func rows(of session: AgentSessionItem) -> [SubagentTreeRow] {
        guard isExpanded(session.id) else { return [] }
        return SubagentTree.rows(for: tasks(of: session), expansion: expansions[session.id] ?? SubagentTreeExpansion())
    }
    public func visibleRows(of session: AgentSessionItem) -> (rows: [SubagentTreeRow], isCut: Bool) {
        ProjectSessions.visible(rows(of: session), showsAll: showsAll(session.id))
    }
    public func collapsedSummary(of session: AgentSessionItem) -> String? { ProjectSessions.runningSummary(tasks(of: session)) }
    public func toggleBranch(_ id: String, level: Int, in session: UUID) {
        var expansion = expansions[session] ?? SubagentTreeExpansion()
        expansion.toggle(id: id, level: level)
        expansions[session] = expansion
    }
    public func toggle(_ session: AgentSessionItem) {
        guard canExpand(session) else { return }
        if expanded.remove(session.id) != nil { return }
        expanded.insert(session.id)
        load(session)
    }
    private func load(_ session: AgentSessionItem) {
        let id = session.id
        guard !pending.contains(id), ProjectSessions.shouldRead(lastReadAt: lastRead[id], now: uptime()), let findTarget, let makeSource else { return }
        pending.insert(id)
        let started = generation
        Task { [weak self] in
            guard let self, generation == started else { return }
            let target = await findTarget(id)
            guard generation == started else { return }
            var snapshot: BackgroundTaskList?
            if let target {
                snapshot = await Task.detached(priority: .userInitiated) {
                    ProjectSessionsTree.read(source: makeSource(target.providerSessionID, target.cwd), sessionID: target.providerSessionID, cwd: target.cwd)
                }.value
            }
            guard generation == started else { return }
            pending.remove(id)
            lastRead[id] = uptime()
            snapshots[id] = snapshot
            var expansion = expansions[id] ?? SubagentTreeExpansion()
            expansion.prune(keeping: Set(tasks(of: session).tasks.map(\.id)))
            expansions[id] = expansion
        }
    }
    public func noteGroupShown(rows: Int) { if rows > 0 { metrics?.projectSessions.opened() } }
    public func noteSubagentOpened() { metrics?.subagentRow.opened() }
    public func clear() {
        generation += 1
        expanded = []; all = []; snapshots = [:]; expansions = [:]; lastRead = [:]; pending = []
    }
}
#endif
