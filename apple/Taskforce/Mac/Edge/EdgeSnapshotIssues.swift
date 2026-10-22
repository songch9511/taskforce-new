#if os(macOS) && DEBUG
import AppKit
import Foundation
import TaskforceKit
import TaskforceUI

/// 견본 데이터 (OA U2 디자인 비교, `-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES -TFEdgeSnapshot <폴더> -TFEdgeSnapshotIssues`): 프로젝트 아이콘 · 이슈 번호 · 세션 · 긴 경우.
/// 서버 응답은 모두 가짜(`IssueSampleGateway` · `IssueSampleContextGateway`)라 렌더 fixture일 뿐이다 (실제 서버 · 계정 · AI 호출 없음).
/// Figma M1 · M3 · M4 · M5 · OA-3 프레임의 문구(Taskforce 0.2.0 · #139 · Pricing copy draft …)를 그대로 쓴다.
enum IssueSnapshotData {
    /// `-TFEdgeSnapshotIssues` 또는 새 셸 견본(`-TFEdgeSnapshotTaskforce`, OA U3)이 같은 견본 서버를 읽는다
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-TFEdgeSnapshotIssues") || arguments.contains("-TFEdgeSnapshotTaskforce")
    }

    // MARK: 아이디

    static func id(_ n: Int, _ prefix: String) -> UUID { UUID(uuidString: String(format: "%@-0000-4000-8000-%012d", prefix, n))! }
    static func issue(_ n: Int) -> UUID { id(n, "15500000") }
    static func project(_ n: Int) -> UUID { id(n, "c0ffee00") }
    static func session(_ n: Int) -> UUID { id(n, "5e550000") }
    static func conversation(_ n: Int) -> UUID { id(n, "d0d00000") }
    static func task(_ n: Int) -> UUID { id(n, "7a7a0000") }
    static let claude = id(1, "c0c00000")
    static let codex = id(2, "c0c00000")

    // MARK: 프로젝트

    static let taskforce = project(1)
    static let shape = project(2)
    static let hiring = project(3)
    static let investor = project(4)
    static let office = project(5)
    static let old = project(9)

    static let baseProjects: [WorkContext] = [
        WorkContext(id: taskforce, name: "Taskforce 0.2.0", contextVersion: 3, icon: .rocket, version: 2),
        WorkContext(id: shape, name: "Shape launch", contextVersion: 5, icon: .megaphone, version: 1),
        WorkContext(id: hiring, name: "Hiring: founding designer", contextVersion: 2, icon: .users, version: 1),
        WorkContext(id: investor, name: "October investor update", contextVersion: 2, icon: .briefcase, version: 1),
        WorkContext(id: office, name: "Seoul office move", contextVersion: 2, icon: .building2, version: 1),
        WorkContext(id: old, name: "Old project", status: .archived, contextVersion: 2, icon: .compass, version: 3),
    ]

    /// 프로젝트가 많은 경우: 긴 이름 포함 열넷 더
    static let manyProjects: [WorkContext] = baseProjects + (0..<14).map { index in
        let names = [
            "Quarterly planning and reporting for the international expansion program",
            "Alpha", "Beta release checklist", "customer interviews", "Design system audit", "Engineering hiring plan", "Finance close",
            "Growth experiments", "Help center rewrite", "Investor relations", "Legal review", "Marketing site", "Partner onboarding", "Support macros",
        ]
        return WorkContext(id: project(20 + index), name: names[index], contextVersion: 1, icon: ProjectIconName.pool[index % 12], version: 1)
    }

    // MARK: 이슈 (번호 · 제목 · 상태 · 기한 · 프로젝트)

    struct Seed {
        let number: Int
        let title: String
        let state: WorkState
        let dueOffset: Int?
        let projects: [UUID]
        var review = false
        var working = false
    }

    static let seeds: [Seed] = [
        Seed(number: 139, title: "Rewrite pricing page copy for the 3-day trial and Lifetime plan", state: .inProgress, dueOffset: 1, projects: [taskforce]),
        Seed(number: 141, title: "Wire EdgeRail rings to live session state", state: .inProgress, dueOffset: 1, projects: [taskforce], working: true),
        Seed(number: 142, title: "Lemon Squeezy webhook retries and idempotency for the paid plan and its refunds", state: .inProgress, dueOffset: nil, projects: [taskforce]),
        Seed(number: 143, title: "Ask Mina to confirm the refund window wording", state: .toDo, dueOffset: -1, projects: [taskforce]),
        Seed(number: 144, title: "Apple sign-in on Mac next to Google", state: .toDo, dueOffset: 5, projects: [taskforce]),
        Seed(number: 138, title: "Privacy policy beta 1.4", state: .done, dueOffset: nil, projects: [taskforce]),
        Seed(number: 150, title: "Pricing tone", state: .inProgress, dueOffset: nil, projects: [shape], review: true),
        Seed(number: 151, title: "Launch email subject lines", state: .toDo, dueOffset: 3, projects: [shape]),
        Seed(number: 152, title: "Offer letter draft", state: .toDo, dueOffset: nil, projects: [hiring]),
        Seed(number: 153, title: "Metrics section", state: .toDo, dueOffset: 2, projects: [investor]),
        Seed(number: 154, title: "Lease signed", state: .done, dueOffset: nil, projects: [office]),
        Seed(number: 155, title: "Send the proposal to Alex", state: .toDo, dueOffset: 4, projects: []),
        Seed(number: 156, title: "Fix the typo in the invoice footer", state: .toDo, dueOffset: nil, projects: [old]),
    ]

    static func action(_ seed: Seed, now: Date = Date()) -> ActionSummary {
        let today = DueDateFormat.today()
        return ActionSummary(
            id: issue(seed.number), title: seed.title, owner: .me, status: seed.state == .done ? .done : .open,
            dueDate: seed.dueOffset.map { today.adding(days: $0) }, counterpart: nil, needsConfirmation: seed.review,
            confirmReasons: seed.review ? ["Needs your answer"] : [], startedAt: seed.state == .inProgress ? now.addingTimeInterval(-3_600) : nil,
            lastActivityAt: now
        )
    }

    /// 이슈를 많이 · 길게: 이름이 긴 프로젝트에 이슈 열 둘
    static let longTitles: [Seed] = (0..<12).map { index in
        Seed(
            number: 300 + index,
            title: index == 0
                ? "Rewrite the entire pricing page, onboarding emails, release notes and the help center article about the Lifetime plan before Thursday"
                : "Issue number \(index + 1) in a list that keeps growing past the panel height",
            state: index < 4 ? .inProgress : .toDo, dueOffset: index % 3 == 0 ? index : nil, projects: [taskforce]
        )
    }

    static func snapshot(seeds: [Seed], load: WorkLoad = .loaded(problem: nil), canConnect: Bool = false) -> EdgeWorkSnapshot {
        let now = Date()
        let actions = seeds.map { (seed: $0, action: action($0, now: now)) }
        let reviews = actions.filter { $0.seed.review }.map(\.action)
        let open = actions.filter { !$0.seed.review && $0.seed.state != .done }.map(\.action)
        let done = actions.filter { $0.seed.state == .done }.map(\.action)
        let today = Calendar.current.startOfDay(for: now)
        return EdgeWorkSnapshot(
            review: reviews, open: open, doneToday: done, working: Set(actions.filter(\.seed.working).map(\.action.id)), stopping: [], reasons: [:],
            load: load, doneSince: today, canConnect: canConnect, syncing: false
        )
    }

    static func members(seeds: [Seed]) -> [ContextMember] {
        var rows: [ContextMember] = []
        for seed in seeds {
            for (index, projectID) in seed.projects.enumerated() {
                rows.append(ContextMember(
                    id: id(seed.number * 10 + index, "d1e50000"), contextID: projectID, actionID: issue(seed.number), origin: .user, confidence: nil, isRemoved: false
                ))
            }
        }
        return rows
    }

    // MARK: 세션

    struct SessionSeed {
        let number: Int
        let name: String
        let connection: UUID
        let status: AgentSessionStatus
        let state: AgentTaskState?
        let issues: [Int]
        var pending = false
        var cancelRequested = false
        var created: Double = 0
    }

    static func sessions(for scenario: IssueSampleGateway.SessionScenario) -> [SessionSeed] {
        switch scenario {
        case .none:
            return []
        case .many:
            // 세션이 아주 많은 경우: 한 이슈에 예순 (Sessions 목록이 패널 높이를 넘는다)
            let states: [AgentTaskState] = [.running, .idle, .awaitingAnswer, .idle, .running]
            return (0..<60).map { index in
                SessionSeed(
                    number: 100 + index, name: index == 7 ? "A session with a very long name that has to be cut before the status word on the right" : "Session \(index + 1)",
                    connection: index.isMultiple(of: 3) ? codex : claude, status: .bound, state: states[index % states.count], issues: [139], created: Double(index)
                )
            }
        case .basic:
            return [
                SessionSeed(number: 1, name: "Pricing copy draft", connection: claude, status: .bound, state: .running, issues: [139], created: 1),
                SessionSeed(number: 2, name: "Lifetime plan section", connection: codex, status: .bound, state: .idle, issues: [139], created: 2),
                SessionSeed(number: 8, name: "Rings and rail", connection: claude, status: .bound, state: .awaitingAnswer, issues: [141], created: 3),
            ]
        case .finished:
            return [
                SessionSeed(number: 1, name: "Pricing copy draft", connection: claude, status: .bound, state: .completed, issues: [139], created: 1),
                SessionSeed(number: 2, name: "Lifetime plan section", connection: codex, status: .bound, state: .idle, issues: [139], created: 2),
                SessionSeed(number: 8, name: "Rings and rail", connection: claude, status: .bound, state: .awaitingAnswer, issues: [141], created: 3),
                SessionSeed(number: 3, name: "Trial wording", connection: claude, status: .bound, state: .running, issues: [141], created: 4),
                SessionSeed(number: 4, name: "Spike: bridge reconnect backoff", connection: claude, status: .closed, state: .idle, issues: [141], created: 5),
            ]
        case .awaiting:
            return [
                SessionSeed(number: 1, name: "Pricing copy draft", connection: claude, status: .bound, state: .awaitingAnswer, issues: [139], created: 1),
                SessionSeed(number: 2, name: "Lifetime plan section", connection: codex, status: .bound, state: .idle, issues: [139], created: 2),
            ]
        case .external:
            return [
                SessionSeed(number: 1, name: "Pricing copy draft", connection: claude, status: .external, state: .idle, issues: [139], created: 1),
                SessionSeed(number: 2, name: "Lifetime plan section", connection: codex, status: .bound, state: .idle, issues: [139], created: 2),
            ]
        case .closedAndStates:
            return [
                SessionSeed(number: 1, name: "Pricing copy draft", connection: claude, status: .closed, state: .idle, issues: [139], created: 1),
                SessionSeed(number: 2, name: "Lifetime plan section", connection: codex, status: .unreachable, state: .running, issues: [139], created: 2),
                SessionSeed(number: 3, name: "Trial wording", connection: claude, status: .bound, state: .running, issues: [139], cancelRequested: true, created: 3),
                SessionSeed(number: 4, name: "Refund window check", connection: claude, status: .bound, state: .idle, issues: [139], pending: true, created: 4),
            ]
        case .nine:
            let states: [AgentTaskState] = [.running, .idle, .awaitingAnswer, .running, .idle, .running, .idle, .running, .idle]
            return (0..<9).map { index in
                SessionSeed(
                    number: 20 + index, name: index == 4 ? "A session with a very long name that has to be cut before the pill and the status line" : "Session \(index + 1)",
                    connection: index.isMultiple(of: 2) ? claude : codex, status: .bound, state: states[index], issues: [139, 141], created: Double(index)
                )
            }
        case .longName:
            return [
                SessionSeed(
                    number: 1, name: "Rewrite the pricing page copy for the trial and the Lifetime plan, keep the refund window wording, then update the help center",
                    connection: claude, status: .bound, state: .running, issues: [139], created: 1
                ),
            ]
        case .longNamePair:
            // 이름이 아주 긴 세션과 보통 세션 (Taskforce 충돌 카드의 두 줄: OA U3)
            return [
                SessionSeed(
                    number: 1, name: "Rewrite the pricing page copy for the trial and the Lifetime plan, keep the refund window wording, then update the help center",
                    connection: claude, status: .bound, state: .running, issues: [139], created: 1
                ),
                SessionSeed(number: 2, name: "Lifetime plan section", connection: codex, status: .bound, state: .idle, issues: [139], created: 2),
            ]
        }
    }

    static let longLine = "Running"

    /// 세션 읽기 모양 (RLS 다섯 표를 한 번에)
    /// - shiftConversations: 세션의 대화 id를 다른 값으로 (시험: 패널의 conversation id가 바뀐 경우)
    static func snapshot(scenario: IssueSampleGateway.SessionScenario, shiftConversations: Bool = false) -> AgentSessionSnapshot {
        let now = Date()
        let seeds = sessions(for: scenario)
        let connections = [AgentConnectionRecord(id: claude, adapter: "agent:claude-code"), AgentConnectionRecord(id: codex, adapter: "agent:codex")]
        var records: [AgentSessionRecord] = []
        var tasks: [AgentTaskRecord] = []
        var runs: [AgentSessionRunRecord] = []
        var conversations: [AgentSessionConversationRecord] = []
        for seed in seeds {
            let created = now.addingTimeInterval(-3_600 + seed.created * 60)
            records.append(AgentSessionRecord(
                id: session(seed.number), connectionID: seed.connection, displayName: seed.name, status: seed.status, isPendingFirstTurn: seed.pending,
                lastTurnSeq: seed.state == nil ? 0 : 1, createdAt: created, updatedAt: created.addingTimeInterval(seed.created)
            ))
            if let state = seed.state, !seed.pending {
                tasks.append(AgentTaskRecord(
                    agentSessionID: session(seed.number), runID: task(seed.number), turnSeq: 1, state: state, lastLiveState: nil,
                    cancelRequestedAt: seed.cancelRequested ? now : nil
                ))
            }
            for (index, issueNumber) in seed.issues.enumerated() {
                runs.append(AgentSessionRunRecord(id: index == 0 ? task(seed.number) : id(seed.number * 10 + index, "7b7b0000"), agentSessionID: session(seed.number), actionID: issue(issueNumber)))
            }
            conversations.append(AgentSessionConversationRecord(id: conversation(seed.number + (shiftConversations ? 100 : 0)), agentSessionID: session(seed.number)))
        }
        return AgentSessionSnapshot(sessions: records, tasks: tasks, runs: runs, connections: connections, conversations: conversations)
    }

    /// 세션 대화 (OA-3 문구)
    static func messages(conversationID: UUID) -> [ChatMessage] {
        let now = Date()
        func agent(_ seq: Int, _ text: String, _ offset: Double) -> ChatMessage {
            ChatMessage(id: id(seq, "a1a10000"), conversationID: conversationID, seq: seq, role: .assistant, text: text, createdAt: now.addingTimeInterval(offset))
        }
        func user(_ seq: Int, _ text: String, _ offset: Double) -> ChatMessage {
            ChatMessage(id: id(seq, "a2a20000"), conversationID: conversationID, seq: seq, role: .user, clientMessageID: id(seq, "a3a30000"), text: text, createdAt: now.addingTimeInterval(offset))
        }
        if conversationID == conversation(1) {
            return [
                agent(1, "Opened pricing.mdx and the Oct 9 pricing decision. Drafting the Pro and Lifetime sections.", -300),
                agent(2, "Draft v2 is ready. 2 of 3 checks passed; the price table check is still running.", -120),
            ]
        }
        if conversationID == conversation(2) {
            return [
                agent(1, "Draft v2 covers the Pro monthly, Pro yearly and Lifetime sections. The trial wording follows the Oct 9 decision, the refund window keeps the three-day limit, and the price table now lists every plan in the same order as the checkout page, with the first month shown for the yearly card and the Lifetime price shown once at the bottom of the table so it never reads as a recurring charge on any card in the list.", -200),
            ]
        }
        return [agent(1, "Working on it.", -60), user(2, "Also update the refund window wording", -30)]
    }

    // MARK: 게이트웨이 교체 (견본 하네스에서만)

    /// `-TFEdgeSnapshotIssues`이면 Chats · 세션 · 번호 · 상세를 읽는 곳을 견본으로 바꾼다 (아니면 그대로)
    /// `-TFEdgeSnapshotAgentChat`이면 에이전트 대화 견본 서버를 읽는다 (OA D4a-1: 전달 줄 · Stop · 알약이 서버처럼 움직인다)
    static func gateway(replacing gateway: any ChatGateway) -> any ChatGateway {
        if AgentChatSnapshot.isEnabled || QuestionSnapshot.isEnabled { return AgentChatSampleGateway.shared }
        return isEnabled ? IssueSampleGateway.shared : gateway
    }

    static func contextGateway(replacing gateway: (any ContextGateway)?) -> (any ContextGateway)? {
        isEnabled || AgentChatSnapshot.isEnabled || QuestionSnapshot.isEnabled ? IssueSampleContextGateway.shared : gateway
    }
}

/// 가짜 범위 서버 (아이콘 · version이 있는 견본 프로젝트와 멤버십). 읽기만 한다
final class IssueSampleContextGateway: ContextGateway, @unchecked Sendable {
    static let shared = IssueSampleContextGateway()

    enum Scenario: Sendable {
        case full, many, empty, offline, failed, hang
    }

    private let lock = NSLock()
    private var _scenario = Scenario.full
    private var _seeds = IssueSnapshotData.seeds

    var scenario: Scenario {
        get { lock.withLock { _scenario } }
        set { lock.withLock { _scenario = newValue } }
    }

    var seeds: [IssueSnapshotData.Seed] {
        get { lock.withLock { _seeds } }
        set { lock.withLock { _seeds = newValue } }
    }

    private func gate() async throws {
        switch scenario {
        case .offline: throw URLError(.notConnectedToInternet)
        case .failed: throw APIError.server(status: 500, code: .internalError, message: "x")
        case .hang: try await Task.sleep(for: .seconds(3_600))
        default: break
        }
    }

    func workContexts() async throws -> [WorkContext] {
        try await gate()
        switch scenario {
        case .empty: return []
        case .many: return IssueSnapshotData.manyProjects
        default: return IssueSnapshotData.baseProjects
        }
    }

    func contextMembers() async throws -> [ContextMember] {
        try await gate()
        return IssueSnapshotData.members(seeds: seeds)
    }

    func changeContextMember(contextID: UUID, op: ContextMemberOp, actionID: UUID, expectedVersion: Int) async throws -> ContextMemberWriteResponse {
        throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)
    }

    func moveContextMember(
        actionID: UUID, from fromContextID: UUID, to toContextID: UUID, expectedToVersion: Int, expectedFromVersion: Int
    ) async throws -> ContextMemberMoveResponse {
        throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)
    }
}

/// 가짜 대화 · 세션 서버: 세션 읽기 · 번호 · 이슈 상세 · 세션 대화. 쓰기는 모두 "기능 꺼짐"이다 (이 하네스는 읽기 화면만 본다)
final class IssueSampleGateway: ChatGateway, IssueScreensGateway, TaskforceRequestGateway, @unchecked Sendable {
    static let shared = IssueSampleGateway()

    enum SessionScenario: Sendable {
        case none, basic, awaiting, external, closedAndStates, nine, longName, longNamePair, many
        /// `.basic`을 한 번 읽은 다음에 바꾸면 "Pricing copy draft"가 방금 끝난 세션(done)이 된다 (OA PR-D2 Sessions: 끝난 줄 · 쉬는 줄 · 닫힌 줄이 함께 있다)
        case finished
    }

    enum ReadScenario: Sendable {
        case full, offline, failed, hang
    }

    private let lock = NSLock()
    private var _sessions = SessionScenario.basic
    private var _reads = ReadScenario.full
    private var _detail = ReadScenario.full
    private var _sources = 2
    private var _slackLeads = false
    private var _hidesConversations = false
    private var _deletesConversations = false
    private var _conversationFailure: Error?
    private var _sessionReads = 0
    private var _conversationReads = 0
    private var _shiftConversations = false
    // Taskforce 대화 (OA U3): 가짜 서버가 내릴 응답 · 읽기 상태 · 충돌 상세 · 해소의 결과. 응답이 없으면 "이 서버는 아직 이 기능이 없다"(404)다
    private var _taskforceResponse: TaskforceReviewResponse?
    private var _taskforceRead = ReadScenario.full
    private var _taskforceDetails: [UUID: TaskforceConflictDetail] = [:]
    private var _taskforceDetailsRead = ReadScenario.full
    private var _resolveFailure: Error?
    private var _resolveDelay: TimeInterval = 0
    private var _taskforceReads = 0
    private var _resolves: [TaskforceResolveRecord] = []

    var sessions: SessionScenario {
        get { lock.withLock { _sessions } }
        set { lock.withLock { _sessions = newValue } }
    }

    /// 세션 · 대화 읽기의 상태
    var reads: ReadScenario {
        get { lock.withLock { _reads } }
        set { lock.withLock { _reads = newValue } }
    }

    /// 이슈 상세 읽기의 상태
    var detail: ReadScenario {
        get { lock.withLock { _detail } }
        set { lock.withLock { _detail = newValue } }
    }

    /// Slack 인용이 가장 새 것 (스냅샷: 서비스 자기 색 마크가 맨 앞 인용에 보인다)
    var slackLeads: Bool {
        get { lock.withLock { _slackLeads } }
        set { lock.withLock { _slackLeads = newValue } }
    }

    /// 대화 목록(History)에 세션의 대화가 없다 (시험: 목록의 최근 100 · 빈 20 밖의 오래된 대화). 행은 id로 직접 읽으면 있다
    var hidesConversationsFromList: Bool {
        get { lock.withLock { _hidesConversations } }
        set { lock.withLock { _hidesConversations = newValue } }
    }

    /// 대화 행을 id로 읽으면 없다 (시험: 다른 곳에서 지운 대화)
    var deletesConversations: Bool {
        get { lock.withLock { _deletesConversations } }
        set { lock.withLock { _deletesConversations = newValue } }
    }

    /// 대화 행을 id로 읽을 때 던지는 오류 (시험: 첫 읽기 실패)
    var conversationFailure: Error? {
        get { lock.withLock { _conversationFailure } }
        set { lock.withLock { _conversationFailure = newValue } }
    }

    /// 세션 읽기를 부른 횟수 (시험: 화면 진입이 세션을 다시 읽는다)
    var sessionReads: Int { lock.withLock { _sessionReads } }
    /// 대화 행을 id로 직접 읽은 횟수 (시험: 세션 패널이 id로 읽는다)
    var conversationReads: Int { lock.withLock { _conversationReads } }
    /// 세션의 대화 id를 다른 값으로 바꾼 읽기 (시험: 패널의 conversation id가 바뀐 경우)
    var shiftsConversations: Bool {
        get { lock.withLock { _shiftConversations } }
        set { lock.withLock { _shiftConversations = newValue } }
    }

    /// 이슈 상세의 원문 인용 수 (0 = 직접 추가한 이슈)
    var sourceCount: Int {
        get { lock.withLock { _sources } }
        set { lock.withLock { _sources = newValue } }
    }

    // MARK: Taskforce (OA U3)

    /// `GET /api/v2/review`가 내릴 응답 (nil = 404, 기능 꺼짐)
    var taskforceResponse: TaskforceReviewResponse? {
        get { lock.withLock { _taskforceResponse } }
        set { lock.withLock { _taskforceResponse = newValue } }
    }

    /// v2 Review 읽기의 상태 (offline · failed · hang)
    var taskforceRead: ReadScenario {
        get { lock.withLock { _taskforceRead } }
        set { lock.withLock { _taskforceRead = newValue } }
    }

    /// 충돌의 경로 · 두 run의 세션
    var taskforceDetails: [UUID: TaskforceConflictDetail] {
        get { lock.withLock { _taskforceDetails } }
        set { lock.withLock { _taskforceDetails = newValue } }
    }

    var taskforceDetailsRead: ReadScenario {
        get { lock.withLock { _taskforceDetailsRead } }
        set { lock.withLock { _taskforceDetailsRead = newValue } }
    }

    /// 해소가 던질 오류 (nil = 200 resolved)
    var resolveFailure: Error? {
        get { lock.withLock { _resolveFailure } }
        set { lock.withLock { _resolveFailure = newValue } }
    }

    /// 해소 요청이 답하기까지 걸리는 초 (스냅샷: 보낸 뒤의 "Answer sent" 장면)
    var resolveDelay: TimeInterval {
        get { lock.withLock { _resolveDelay } }
        set { lock.withLock { _resolveDelay = newValue } }
    }

    var taskforceReads: Int { lock.withLock { _taskforceReads } }
    var resolves: [TaskforceResolveRecord] { lock.withLock { _resolves } }

    func taskforceReview() async throws -> TaskforceReviewResponse {
        let (scenario, response) = lock.withLock { () -> (ReadScenario, TaskforceReviewResponse?) in
            _taskforceReads += 1
            return (_taskforceRead, _taskforceResponse)
        }
        try await gate(scenario)
        guard let response else { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
        return response
    }

    func pathConflictDetails(_ refs: [TaskforceConflictRef]) async throws -> [UUID: TaskforceConflictDetail] {
        let (scenario, details) = lock.withLock { (_taskforceDetailsRead, _taskforceDetails) }
        try await gate(scenario)
        return details.filter { entry in refs.contains { $0.leaseID == entry.key } }
    }

    func resolvePathConflict(leaseID: UUID, keep: TaskforceConflictKeep, conflictVersion: Int) async throws -> TaskforceResolveConflictResponse {
        let failure = lock.withLock { () -> Error? in
            _resolves.append(TaskforceResolveRecord(leaseID: leaseID, keep: keep, conflictVersion: conflictVersion))
            return _resolveFailure
        }
        let delay = lock.withLock { _resolveDelay }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if let failure { throw failure }
        return try JSONDecoder().decode(TaskforceResolveConflictResponse.self, from: Data(#"{"status":"resolved"}"#.utf8))
    }

    private func gate(_ scenario: ReadScenario) async throws {
        switch scenario {
        case .offline: throw URLError(.notConnectedToInternet)
        case .failed: throw APIError.server(status: 500, code: .internalError, message: "x")
        case .hang: try await Task.sleep(for: .seconds(3_600))
        case .full: break
        }
    }

    // MARK: IssueScreensGateway

    func actionNumbers(ids: [UUID]) async throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for seed in IssueSnapshotData.seeds + IssueSnapshotData.longTitles where ids.contains(IssueSnapshotData.issue(seed.number)) {
            result[IssueSnapshotData.issue(seed.number)] = seed.number
        }
        return result
    }

    func issueDetail(id: UUID) async throws -> ActionDetail {
        try await gate(detail)
        let seed = (IssueSnapshotData.seeds + IssueSnapshotData.longTitles).first { IssueSnapshotData.issue($0.number) == id }
        let number = seed?.number ?? 0
        let record = try TaskforceJSON.decoder().decode(ActionRecord.self, from: Data("""
        {"id":"\(id.uuidString.lowercased())","title":"\(seed?.title ?? "")","scope_summary":null,"owner":"me","counterpart":null,"due_date":null,"status":"open",
         "needs_confirmation":false,"confirm_reasons":[],"started_at":null,"last_activity_at":"2026-10-14T01:00:00.000Z","created_at":"2026-10-13T01:00:00.000Z","number":\(number)}
        """.utf8))
        let slack = IssueSnapshotData.id(1, "50000000")
        let notion = IssueSnapshotData.id(2, "50000000")
        let sources: [SourceSummary] = [
            try TaskforceJSON.decoder().decode(SourceSummary.self, from: Data("""
            {"id":"\(slack.uuidString.lowercased())","kind":"message","title":"#pricing · Mina","occurred_at":"2026-10-10T01:00:00.000Z","external_url":"https://acme.slack.com/archives/C1/p1","created_at":"2026-10-10T01:00:00.000Z","processing_status":"done","meeting":null}
            """.utf8)),
            try TaskforceJSON.decoder().decode(SourceSummary.self, from: Data("""
            {"id":"\(notion.uuidString.lowercased())","kind":"meeting","title":"Pricing sync","occurred_at":"2026-10-12T01:00:00.000Z","external_url":"https://www.notion.so/x","created_at":"2026-10-12T01:00:00.000Z","processing_status":"done","meeting":null}
            """.utf8)),
        ]
        let quotes = [
            (slack, "Can the pricing copy ship before Thursday?", Date(timeIntervalSince1970: slackLeads ? 1_791_400_000 : 1_791_000_000)),
            (notion, "Mina to confirm the refund window wording by Friday", Date(timeIntervalSince1970: 1_791_200_000)),
        ].prefix(sourceCount)
        let evidence = quotes.map { quote in
            EvidenceRecord(id: UUID(), actionID: id, sourceID: quote.0, quote: quote.1, role: .created, createdAt: quote.2)
        }
        return ActionDetail(action: record, evidence: Array(evidence), sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) }), events: [])
    }

    func agentSessionSnapshot() async throws -> AgentSessionSnapshot {
        lock.withLock { _sessionReads += 1 }
        try await gate(reads)
        return IssueSnapshotData.snapshot(scenario: sessions, shiftConversations: shiftsConversations)
    }

    // MARK: ChatGateway (읽기만)

    func conversation(id: UUID) async throws -> ChatConversation? {
        let (failure, deleted) = lock.withLock { () -> (Error?, Bool) in
            _conversationReads += 1
            return (_conversationFailure, _deletesConversations)
        }
        if let failure { throw failure }
        if deleted { return nil }
        return try await conversationRows().first { $0.id == id }
    }

    func conversations() async throws -> [ChatConversation] {
        if lock.withLock({ _hidesConversations }) { return [] }
        return try await conversationRows()
    }

    private func conversationRows() async throws -> [ChatConversation] {
        try await gate(reads)
        let snapshot = IssueSnapshotData.snapshot(scenario: sessions, shiftConversations: shiftsConversations)
        return snapshot.conversations.map { row in
            ChatConversation(
                id: row.id, title: nil, contextID: nil, createdAt: Date().addingTimeInterval(-3_600), lastMessageAt: Date().addingTimeInterval(-60),
                target: ChatConversationTarget(kind: .agent, agentConnectionID: snapshot.sessions.first { $0.id == row.agentSessionID }?.connectionID, agentSessionID: row.agentSessionID)
            )
        }
    }

    func lastMessages(conversationIDs: [UUID]) async throws -> [UUID: ChatMessage] { [:] }

    func messages(conversationID: UUID) async throws -> [ChatMessage] {
        try await gate(reads)
        return IssueSnapshotData.messages(conversationID: conversationID)
    }

    func message(id: UUID) async throws -> ChatMessage? { nil }
    func workContexts() async throws -> [WorkContext] { IssueSnapshotData.baseProjects }
    func currentMemoryItems() async throws -> [MemoryItem] { [] }
    func memoryItems(ids: [UUID]) async throws -> [MemoryItem] { [] }
    func memorySource(id: UUID) async throws -> MemorySource? { nil }

    private func off<T>() throws -> T { throw APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage) }
    func createConversation(id: UUID, title: String?, contextID: UUID?) async throws -> ChatConversation { try off() }
    func updateConversation(id: UUID, contextID: UUID?) async throws -> ChatConversation { try off() }
    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String) async throws -> ChatPostedMessage { try off() }
    func confirmMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { try off() }
    func editMemory(id: UUID, edit: MemoryEdit) async throws -> MemoryItem { try off() }
    func forgetMemory(id: UUID, expectedVersion: Int) async throws -> MemoryItem { try off() }
    func moveMemory(id: UUID, expectedVersion: Int, to target: MemoryTarget) async throws -> MemoryItem { try off() }
}

/// 가짜 서버가 받은 경로 충돌 해소 하나 (OA U3 시험)
struct TaskforceResolveRecord: Equatable, Sendable {
    let leaseID: UUID
    let keep: TaskforceConflictKeep
    let conflictVersion: Int
}

/// 새 Issues 화면 PNG (OA U2, 디자인 비교용): `-TF_EDGE_SHELL YES -TFSampleData -TF_S3B YES -TF_U2 YES -TFEdgeSnapshot <폴더> -TFEdgeSnapshotIssues`
/// (+ `-TFSnapshotDark`, `-TFReduceMotion YES`). 화면 녹화 권한 없이 자기 창(캡슐 레일 · 이슈 패널 · 세션 패널 · 메뉴)의 내용만 그려 데스크톱 견본 위에 실제 자리대로 붙인다.
/// 남기는 것(`mac-edge-issues-<이름>.png`): projects(M1) · projects-ask · projects-many · projects-empty · projects-loading/offline/failed · list-project(M3) ·
/// list-ungrouped · list-done-today · list-many(긴 제목 · 많은 이슈) · list-ask · detail-many · detail(M4) · detail-states · detail-no-source · detail-no-sessions · detail-nine ·
/// detail-loading/offline/failed · detail-long · session-running · session-needs · session-idle · session-external · session-closed · session-in-nine · session-long-name · session-unreachable.
/// 서버 응답은 가짜(`IssueSampleGateway` · `IssueSampleContextGateway`)라 렌더 fixture일 뿐이다.
@MainActor
enum IssueSnapshot {
    static func capture(_ edge: EdgeShellController, file: (String) -> URL, pause: @escaping (Double) async -> Void) async {
        // 에이전트 대화 장면(OA D4a-1)은 같은 인자에 `-TFEdgeSnapshotAgentChat`을 더하면 따로 돈다
        if AgentChatSnapshot.isEnabled {
            await AgentChatSnapshot.capture(edge, file: file, pause: pause)
            return
        }
        // 레일 On this Mac(OA 외부 세션 PR1)은 같은 인자에 `-TFEdgeSnapshotExternalSessions`를 더하면 따로 돈다
        if ExternalSessionSnapshot.isEnabled {
            await ExternalSessionSnapshot.capture(edge, file: file, pause: pause)
            return
        }
        // 에이전트 질문 카드 장면(OA D4b-m-1)은 같은 인자에 `-TFEdgeSnapshotQuestions`를 더하면 따로 돈다
        if QuestionSnapshot.isEnabled {
            await QuestionSnapshot.capture(edge, file: file, pause: pause)
            return
        }
        guard let runtime = edge.chat, let issues = runtime.issues, let contexts = runtime.contexts else {
            print("IssueSnapshot: 새 Issues 화면이 꺼진 구성이다 (-TF_EDGE_SHELL YES -TF_S3B YES -TF_U2 YES 필요) chat=\(edge.chat != nil) issues=\(edge.chat?.issues != nil)")
            return
        }
        let shell = edge.shell
        // 실제 포인터가 패널 위에 있으면 그 행이 호버로 그려진다: 포인터를 화면 왼쪽 가장자리 가운데(패널 · 핫코너 밖)에 치워 두고 끝나면 되돌린다
        let parked = parkPointer()
        defer { parked() }
        // 알약은 동작이 주어질 때만 보인다 (U2-41: 앱에서는 비어 있고 견본 하네스만 채운다): 눌러도 아무 일도 없다
        shell.onSessionPill = { _, _ in }
        let sample = IssueSampleGateway.shared
        let contextSample = IssueSampleContextGateway.shared
        func settle(_ seconds: Double = 0.8) async { await pause(seconds) }
        func shoot(_ name: String) { compose(edge, to: file("issues-\(name)")) }

        /// 새 계정이 막 로그인한 것처럼 저장소를 비우고 가짜 서버 시나리오대로 다시 읽는다
        func world(
            seeds: [IssueSnapshotData.Seed] = IssueSnapshotData.seeds, sessions: IssueSampleGateway.SessionScenario = .basic,
            reads: IssueSampleGateway.ReadScenario = .full, detail: IssueSampleGateway.ReadScenario = .full, sources: Int = 2, slackLeads: Bool = false,
            contexts scenario: IssueSampleContextGateway.Scenario = .full, load: WorkLoad = .loaded(problem: nil)
        ) async {
            sample.slackLeads = slackLeads
            sample.sessions = sessions
            sample.reads = reads
            sample.detail = detail
            sample.sourceCount = sources
            contextSample.scenario = scenario
            contextSample.seeds = seeds
            runtime.scope.accountLeft()
            edge.workOverride = { _ in IssueSnapshotData.snapshot(seeds: seeds, load: load) }
            shell.openAllWork()
            let ids = seeds.map { IssueSnapshotData.issue($0.number) }
            Task { await contexts.refresh() }
            await issues.numbers.ensure(ids)
            await issues.sessions.refresh()
            await settle()
        }
        func list(_ scope: IssueListScope) async {
            shell.openAllWork()
            shell.openList(scope)
            await settle()
        }
        func detail(_ number: Int, session: Int? = nil) async {
            shell.openAllWork()
            shell.openIssue(IssueSnapshotData.issue(number))
            await settle()
            if let session {
                shell.openSession(IssueSnapshotData.session(session))
                await settle(1.2)
            }
        }

        // 프로젝트 목록 (M1)
        await world()
        shell.openAllWork()
        await settle()
        shoot("projects")
        // Ask 알약은 호버한 모양으로: 행 이름을 먼저 정하고 화면을 다시 연다 (이미 그려진 행은 다시 그리지 않는다)
        PanelRowSnapshot.askingNames = Set(shell.projectRows.filter { $0.name == "Taskforce 0.2.0" }.map(\.accessibilityName))
        await list(.doneToday)
        shell.goBack()
        await settle(0.5)
        shoot("projects-ask")
        PanelRowSnapshot.askingNames = []

        // 이슈 목록 (M3): 프로젝트 · Ungrouped · Done today
        await list(.project(IssueSnapshotData.taskforce))
        shoot("list-project")
        if let first = shell.issueList(.project(IssueSnapshotData.taskforce))?.groups.first?.rows.first {
            PanelRowSnapshot.askingNames = [first.accessibilityLabel]
            await list(.project(IssueSnapshotData.taskforce))
            shoot("list-ask")
            PanelRowSnapshot.askingNames = []
        }
        await list(.ungrouped)
        shoot("list-ungrouped")
        await list(.doneToday)
        shoot("list-done-today")
        await list(.project(IssueSnapshotData.shape))
        shoot("list-project-review")

        // 이슈 상세 (M4) + 상태들
        await detail(139)
        shoot("detail")
        if let session = shell.sessions(of: IssueSnapshotData.issue(139)).first {
            PanelRowSnapshot.askingNames = [session.rowAccessibilityName]
            await detail(139)
            shoot("detail-ask")
            PanelRowSnapshot.askingNames = []
        }
        await detail(141)
        shoot("detail-needs")
        await detail(155)
        shoot("detail-ungrouped")
        // DS SourceMark: 서비스 자기 색의 공식 마크 (Slack · Notion), 마크가 없는 출처(붙여 넣은 원문)는 점선 빈 타일
        await world(slackLeads: true)
        await detail(139)
        shoot("detail-source-slack")
        await world(sources: 0)
        await detail(139)
        shoot("detail-no-source")
        await world(sessions: .none)
        await detail(139)
        shoot("detail-no-sessions")
        await world(sessions: .closedAndStates)
        await detail(139)
        shoot("detail-states")
        await world(sessions: .external)
        await detail(139)
        shoot("detail-external")

        // 세션 패널 (M5 · OA-3)
        await world(sessions: .basic)
        await detail(139, session: 1)
        shoot("session-running")
        // 꺼진 알약의 툴팁은 호버한 모양으로: 켜 두고 세션 패널을 다시 연다
        PanelHeaderSnapshot.showsPillTooltip = true
        await detail(139, session: 1)
        shoot("session-running-tooltip")
        PanelHeaderSnapshot.showsPillTooltip = false
        await world(sessions: .awaiting)
        await detail(139, session: 1)
        shoot("session-needs")
        PanelHeaderSnapshot.showsPillTooltip = true
        await detail(139, session: 1)
        shoot("session-needs-tooltip")
        PanelHeaderSnapshot.showsPillTooltip = false
        await world(sessions: .basic)
        await detail(139, session: 2)
        shoot("session-idle")
        await world(sessions: .external)
        await detail(139, session: 1)
        shoot("session-external")
        await world(sessions: .closedAndStates)
        await detail(139, session: 1)
        shoot("session-closed")
        await detail(139, session: 2)
        shoot("session-unreachable")
        await detail(139, session: 3)
        shoot("session-stop-requested")
        await detail(139, session: 4)
        shoot("session-pending")
        await world(sessions: .nine)
        await detail(139, session: 21)
        shoot("session-in-nine")
        await detail(139, session: 24)
        shoot("session-long-name-in-list")
        await world(sessions: .longName)
        await detail(139, session: 1)
        shoot("session-long-name")

        // 많은 경우: 이슈 상세의 Sessions 목록이 길어진다 (세션은 이 목록 한 곳에서만 연다)
        await world(sessions: .nine)
        await detail(139)
        shoot("detail-nine")
        await list(.project(IssueSnapshotData.taskforce))
        shoot("list-nine")

        // 세션이 아주 많은 경우: 이슈 상세가 화면 높이에서 스크롤
        await world(sessions: .many)
        await detail(139)
        shoot("detail-many")

        // 긴 제목 · 많은 이슈 · 많은 프로젝트
        let many = IssueSnapshotData.seeds + IssueSnapshotData.longTitles
        await world(seeds: many, sessions: .basic, contexts: .many)
        shell.openAllWork()
        await settle()
        shoot("projects-many")
        await list(.project(IssueSnapshotData.taskforce))
        shoot("list-many")
        await detail(300)
        shoot("detail-long")

        // 읽기 상태
        await world(contexts: .empty)
        shell.openAllWork()
        await settle()
        shoot("projects-no-projects")
        for (name, scenario) in [("loading", IssueSampleContextGateway.Scenario.hang), ("offline", .offline), ("failed", .failed)] {
            await world(contexts: scenario)
            shell.openAllWork()
            await settle()
            shoot("projects-\(name)")
        }
        await world(seeds: [], contexts: .full, load: .loaded(problem: nil))
        shell.openAllWork()
        await settle()
        shoot("projects-empty")
        for (name, scenario) in [("loading", IssueSampleGateway.ReadScenario.hang), ("offline", .offline), ("failed", .failed)] {
            await world(detail: scenario)
            await detail(139)
            shoot("detail-\(name)")
        }
        await world(reads: .offline)
        await detail(139)
        shoot("detail-sessions-offline")
        await world()
        shell.openAllWork()
    }



    /// 포인터를 패널에서 먼 곳(왼쪽 가장자리 가운데)으로 옮기고, 원래 자리로 되돌리는 함수를 돌려준다 (견본 하네스에서만)
    private static func parkPointer() -> () -> Void {
        guard let screen = NSScreen.screens.first else { return {} }
        let original = NSEvent.mouseLocation
        let height = screen.frame.height
        CGWarpMouseCursorPosition(CGPoint(x: 12, y: height / 2))
        return { CGWarpMouseCursorPosition(CGPoint(x: original.x, y: height - original.y)) }
    }

    /// 보이는 창(레일 · 이슈 패널 · 세션 패널 · 메뉴)을 화면 자리대로, 데스크톱 견본 위에 그린다
    static func compose(_ edge: EdgeShellController, to url: URL) {
        var windows: [NSWindow] = [edge.panel.panel, edge.rail.panel].filter(\.isVisible)
        if let session = edge.sessionPanel?.panel, session.isVisible { windows.append(session) }
        if let claude = edge.claudePanel?.panel, claude.isVisible { windows.append(claude) }
        if let menu = edge.menu.window, menu.isVisible { windows.append(menu) }
        if let card = edge.rail.moreCard.window, card.isVisible { windows.append(card) }
        guard let first = windows.first else { return }
        let margin: CGFloat = 24
        let bounds = windows.map(\.frame).reduce(first.frame) { $0.union($1) }
        let canvas = CGRect(x: bounds.minX - margin, y: bounds.minY - margin, width: bounds.width + margin, height: bounds.height + 2 * margin)
        let scale = first.backingScaleFactor
        guard let context = CGContext(
            data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        drawDesktop(in: context, size: canvas.size)
        for window in windows {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            context.saveGState()
            context.setAlpha(window.alphaValue)
            context.draw(image, in: CGRect(x: window.frame.minX - canvas.minX, y: window.frame.minY - canvas.minY, width: window.frame.width, height: window.frame.height))
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = canvas.size
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func drawDesktop(in context: CGContext, size: CGSize) {
        let colors = ["7d8794", "857a80", "857968", "4a3c3e"].map { hex -> CGColor in
            let value = UInt32(hex, radix: 16) ?? 0
            return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.42, 0.62, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
    }
}
#endif
