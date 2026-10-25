#if os(macOS)
import AppKit
import Foundation
import Observation
import TaskforceKit

// 패널 옆줄(side pane)의 상태 (DZ oa-session-view-dz v2 E7–E11): 세션이 돌리는 백그라운드 일이 있을 때만 패널의 바깥 가장자리에 붙는 접힌 띠(36) · 펼친 옆줄(256).
// 두 세션 패널(Claude 읽기 전용 · Taskforce)이 같은 모델을 쓴다: 일 목록은 쓰는 쪽이 먹이고(Claude: 기록의 시작 · 끝 줄, Taskforce: 어댑터의 `task_*` 줄 + 이 Mac의 기록), 모델은 보일지 · 펼칠지 · 어디에 설지를 정한다.
// 화면 상태일 뿐이다: 서버 · 로그 · 지표 0. "열어 본 시각"만 이 Mac에 저장한다 (`BackgroundTaskOpenStore`).

/// 옆줄이 서는 자리 (DZ v2 E11). 순수한 규칙이다 (창 · 화면을 만지지 않는다)
enum SidePaneLayout {
    static let stripWidth: CGFloat = 36
    static let paneWidth: CGFloat = 256

    struct Plan: Equatable {
        /// 패널 창을 왼쪽으로 이만큼 넓혀 바깥에 선다 (패널과 같은 위 · 높이)
        var outside: CGFloat
        /// 띠가 패널 틀 안으로 들어가 대화 폭을 이만큼 줄인다 (왼쪽 여유가 36보다 작을 때)
        var cut: CGFloat
        /// 펼침이 패널의 왼쪽 위로 덮는다 (왼쪽 여유가 256보다 작을 때)
        var overlay: Bool

        static let none = Plan(outside: 0, cut: 0, overlay: false)
    }

    /// - visible: 옆줄이 있나 (띠 또는 펼침)
    /// - expanded: 펼침인가 (아니면 띠)
    /// - room: 패널 왼쪽 끝에서 보이는 화면(`visibleFrame`)의 왼쪽 끝까지의 거리
    static func plan(visible: Bool, expanded: Bool, room: CGFloat) -> Plan {
        guard visible else { return .none }
        if expanded { return room >= paneWidth ? Plan(outside: paneWidth, cut: 0, overlay: false) : Plan(outside: 0, cut: 0, overlay: true) }
        return room >= stripWidth ? Plan(outside: stripWidth, cut: 0, overlay: false) : Plan(outside: 0, cut: stripWidth, overlay: false)
    }

    /// 옆줄 창 틀을 더한 패널 창의 자리: 오른쪽(레일 쪽)과 위 · 높이는 그대로, 왼쪽으로만 `outside`만큼 넓힌다
    static func windowFrame(panel: NSRect, outside: CGFloat) -> NSRect {
        NSRect(x: panel.minX - outside, y: panel.minY, width: panel.width + outside, height: panel.height)
    }
}

@MainActor
@Observable
final class SessionSidePaneModel {
    /// 일 목록 (쓰는 쪽이 먹인다). 하위 에이전트면 부모 · 깊이가 붙어 있고 옆줄은 이것을 트리로 그린다
    var tasks = BackgroundTaskList() {
        didSet {
            if treeExpansion.count > 0 { treeExpansion.prune(keeping: Set(tasks.tasks.map(\.id))) }
            windowMayHaveChanged()
            if hasAgentTree && !rootChatOpen && !oldValue.tasks.contains(where: { $0.kind == .agent }) { onRootInputHidden?() }
        }
    }
    /// 트리의 접힘 · 펼침 선택 (기본은 2단계까지 펴 둔다): 갱신이 와도 사용자가 고른 것은 그대로이고, 세션을 바꾸면 비운다
    private(set) var treeExpansion = SubagentTreeExpansion()
    var canvasExpansion = SubagentTreeExpansion(visibleLevels: 17)
    var rootExpanded = true
    var focusedCardID: String?
    private(set) var rootChatOpen = false { didSet { windowMayHaveChanged() } }
    var usesAgentCanvas = false
    var canvasWidth: CGFloat = 784
    var hasAgentTree: Bool { usesAgentCanvas && effective.tasks.contains { $0.kind == .agent } }
    @ObservationIgnored var onRootInputHidden: (() -> Void)?
    var allowsRootInput: Bool { !hasAgentTree || selectedID == nil }
    var showsTree: Bool { hasAgentTree && !rootChatOpen }
    var canvasRows: [SubagentTreeRow] { SubagentTree.rows(for: effective, expansion: canvasExpansion) }

    private var childDrafts: [String: String] = [:]
    private(set) var draftGeneration = UUID()
    func draft(for id: String) -> String { childDrafts[id] ?? "" }
    func setDraft(_ value: String, for id: String) {
        guard showsTree, selectedID == id else { return }
        childDrafts[id] = value
    }

    /// Accepted messages clear only their original, unchanged draft, even after selection moves.
    func reconcileDraft(for id: String, matching draft: String, generation: UUID) {
        guard draftGeneration == generation, childDrafts[id] == draft else { return }
        childDrafts[id] = nil
    }

    func selectRootInTree() { back(); rootChatOpen = false }
    func openRootChat() { back(); rootChatOpen = true }
    func returnToTree() { back(); rootChatOpen = false; onRootInputHidden?() }
    func openAgentChat(_ id: String) { _ = reveal(id) }

    @discardableResult
    func reveal(_ id: String) -> Bool {
        guard effective.tasks.contains(where: { $0.id == id }) else { return false }
        if allowsRootInput { onRootInputHidden?() }
        rootChatOpen = false
        expanded = true
        select(id)
        return true
    }
    /// 패널 왼쪽 끝에서 화면 왼쪽 끝까지의 여유 (컨트롤러가 창 자리에서 잰다). 모르면 넉넉하다고 본다
    var room: CGFloat = .greatestFiniteMagnitude { didSet { windowMayHaveChanged() } }

    private(set) var expanded = false { didSet { windowMayHaveChanged() } }
    private(set) var selectedID: String? { didSet { windowMayHaveChanged() } }
    /// 이 세션의 목록을 마지막으로 열어 본 시각 (이 Mac에 저장)
    private(set) var openedAt: Date? { didSet { windowMayHaveChanged() } }
    /// 세션이 닫힌 때 (Claude에서 닫음): 그때까지 돌던 일은 Stopped다
    private(set) var closedAt: Date? { didSet { windowMayHaveChanged() } }
    /// 열린 일의 출력 꼬리 (일을 누르면 만들고, 뒤로 · 접으면 멈추고 버린다). 못 읽는 세션이면 nil
    private(set) var tail: BackgroundTaskTailModel?
    /// 소유자가 준다: 그 일의 출력 꼬리 읽기를 만든다 (이 Mac의 기록 · 임시 폴더에서). 없으면 일을 눌러도 꼬리는 못 읽음이다
    @ObservationIgnored var makeTail: ((BackgroundTask) -> BackgroundTaskTailModel)?

    @ObservationIgnored private let store: any BackgroundTaskOpenStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private(set) var sessionKey: String?

    init(store: any BackgroundTaskOpenStore, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    /// 옆줄이 창에 요구하는 폭(`windowExtra`)이 바뀌었다: 컨트롤러가 **그 자리에서** 창 틀을 맞춘다 (모델이 바뀐 바로 그 호출 안에서: 다음 루프 · 관찰의 한 박자를 기다리면 내용이 낡은 창에 잠깐 잘리거나 쏠린다)
    @ObservationIgnored var onWindowChange: (() -> Void)?
    @ObservationIgnored private var notifiedExtra: CGFloat = 0
    @ObservationIgnored private var notifiedTree = false
    @ObservationIgnored private var batching = 0

    private func windowMayHaveChanged() {
        guard batching == 0 else { return }
        let extra = windowExtra
        guard extra != notifiedExtra || hasAgentTree != notifiedTree else { return }
        notifiedExtra = extra
        notifiedTree = hasAgentTree
        onWindowChange?()
    }

    /// 한 번에 여러 값을 바꾸는 동안은 중간 폭으로 창을 맞추지 않는다 (끝난 뒤 한 번)
    private func batched(_ body: () -> Void) {
        batching += 1
        body()
        batching -= 1
        windowMayHaveChanged()
    }

    /// 다른 세션으로 바뀌었다: 그 세션의 열어 본 시각을 읽고 접힌 채로 시작한다
    func attach(session key: String?) {
        guard key != sessionKey else { return }
        sessionKey = key
        batched {
            openedAt = key.flatMap { store.openedAt(session: $0) }
            expanded = false
            dropTail()
            selectedID = nil
            closedAt = nil
            treeExpansion = SubagentTreeExpansion()
            canvasExpansion = SubagentTreeExpansion(visibleLevels: 17)
            rootExpanded = true
            focusedCardID = nil
            rootChatOpen = false
            childDrafts.removeAll()
            draftGeneration = UUID()
            tasks = BackgroundTaskList()
        }
    }

    private func dropTail() {
        tail?.stop()
        tail = nil
    }

    /// Claude에서 세션이 닫혔다 (한 번만 시각을 적는다). 다시 살아나면 풀린다
    func setClosed(_ closed: Bool) {
        if closed { if closedAt == nil { closedAt = clock() } } else { closedAt = nil }
    }

    /// 보이는 목록: 닫힌 세션이면 돌던 일은 멈춘 것으로
    var effective: BackgroundTaskList { closedAt.map { tasks.closed(at: $0) } ?? tasks }

    /// 옆줄이 있나: 도는 일이 있거나 막 끝난 일을 아직 열어 보지 않았다. 펼쳐 둔 동안은 늘 있다 (열었더니 사라지지 않게)
    var visible: Bool { expanded || BackgroundTaskVisibility.isVisible(tasks: effective.tasks, openedAt: openedAt) }

    var plan: SidePaneLayout.Plan { SidePaneLayout.plan(visible: visible, expanded: expanded, room: room) }

    /// 패널 창이 왼쪽으로 넓어지는 폭 (컨트롤러가 관찰한다)
    var windowExtra: CGFloat { hasAgentTree ? (showsTree ? canvasWidth - EdgePanelMetrics.width : 0) : plan.outside }

    /// 보이는 트리 줄 (접힌 분기의 자손은 나오지 않는다)
    var treeRows: [SubagentTreeRow] { SubagentTree.rows(for: effective, expansion: treeExpansion) }

    /// 줄의 꺾쇠를 눌렀다: 그 분기를 접거나 편다 (열려 있는 꼬리 보기 · 선택은 건드리지 않는다)
    func toggleBranch(_ id: String, level: Int) {
        treeExpansion.toggle(id: id, level: level)
    }

    /// 열린 일 (꼬리 보기). 목록에서 사라졌으면 nil
    var selected: BackgroundTask? { selectedID.flatMap { id in effective.tasks.first { $0.id == id } } }

    /// 띠를 눌렀다: 펼친다. 열어 본 시각을 이 Mac에 적는다 (막 끝난 일은 이제 본 것이다)
    func expand() {
        guard visible, !expanded else { return }
        expanded = true
        stamp()
    }

    /// 접는다 (꼬리 보기도 닫는다). 접고 나서 도는 일이 없고 본 것뿐이면 옆줄이 사라진다
    func collapse() {
        guard expanded else { return }
        stamp()
        expanded = false
        dropTail()
        selectedID = nil
    }

    /// 일 하나를 연다 (꼬리 보기): 출력 읽기를 시작한다. 도는 일이면 1초마다 이어 읽는다
    func select(_ id: String) {
        guard expanded, let task = effective.tasks.first(where: { $0.id == id }) else { return }
        dropTail()
        selectedID = id
        guard let made = makeTail?(task) else { return }
        tail = made
        made.start { [weak self] in self?.effective.tasks.first(where: { $0.id == id })?.status == .running }
    }

    func back() {
        dropTail()
        selectedID = nil
    }

    /// Esc: 꼬리 → 목록 → 접힘 → (패널). 처리했으면 true, 옆줄이 접혀 있으면 false (패널이 받는다)
    func escape() -> Bool {
        if hasAgentTree {
            guard rootChatOpen || selectedID != nil else { return false }
            returnToTree()
            return true
        }
        if selectedID != nil {
            back()
            return true
        }
        if expanded {
            collapse()
            return true
        }
        return false
    }

    private func stamp() {
        guard let key = sessionKey else { return }
        let now = clock()
        store.markOpened(session: key, at: now)
        openedAt = now
    }
}

/// 한 일의 출력 꼬리 상태 (DZ v2 E10): 열려 있는 동안 1초마다 이어 읽는다 (도는 일만. 끝난 일은 한 번 읽고 멈춘다). 읽기는 메인 밖에서 한다. 글 · 경로를 로그에 남기지 않는다.
/// - **읽기는 한 번에 하나다**: 읽는 중에 창을 넓히거나 Try again을 누르면 그 읽기가 끝나기를 기다렸다가 다시 읽는다 (같은 파일을 겹쳐 읽지 않는다)
/// - **마지막으로 부탁한 것이 이긴다**: 창 · Try again이 바뀐 뒤에 끝난 옛 읽기의 결과는 버린다 (느린 옛 창의 결과가 새 창의 결과를 덮지 않는다)
/// - 이어 읽기: 크기가 그대로면 화면을 건드리지 않고, 에이전트는 새로 붙은 줄만 받아 덧붙인다 (`BackgroundTaskTail.update`)
@MainActor
@Observable
final class BackgroundTaskTailModel {
    enum State: Equatable {
        case loading
        /// 아직 출력이 없다 ("No output yet")
        case empty
        case text(String, hasEarlier: Bool)
        case agent([ClaudeAppTurn], hasEarlier: Bool)
        /// 못 읽었다 ("Couldn't load this output" + Try again)
        case unavailable
    }

    static let interval: Duration = .seconds(1)
    /// "Show earlier"가 창을 넓히는 배수 (16 KiB → 64 KiB → 256 KiB, 그 이상은 없다)
    static let widening = 4

    private(set) var state = State.loading
    private(set) var window: Int
    let taskID: String
    @ObservationIgnored private let source: @Sendable (Int, BackgroundTaskTail.Cursor?) -> BackgroundTaskTail.Update
    @ObservationIgnored private let limits: BackgroundTaskTail.Limits
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 그 일이 아직 도는가 (끝난 일은 한 번 읽고 멈춘다). 열 때 소유자가 준다
    @ObservationIgnored private var isRunning: @MainActor () -> Bool = { false }
    @ObservationIgnored private let pause: @Sendable (Duration) async -> Void
    /// 앞 읽기가 남긴 자리 · 에이전트의 지금까지 받은 줄 (이어 읽기가 덧붙인다)
    @ObservationIgnored private var cursor: BackgroundTaskTail.Cursor?
    @ObservationIgnored private var agentTurns: [ClaudeAppTurn] = []
    @ObservationIgnored private var agentEarlier = false
    /// 창 · Try again · 멈춤이 바뀔 때마다 오른다: 그 전에 시작한 읽기의 결과는 낡았다
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    /// 멈췄다 (뒤로 · 접기 · 다른 일): 더 읽지 않고 읽는 중이던 결과도 버린다
    @ObservationIgnored private var stopped = false

    /// - read: 창 크기(바이트)를 받아 그 일의 꼬리를 통째로 읽는다 (메인 밖에서 불린다). 이어 읽기는 하지 않는다
    convenience init(
        taskID: String, limits: BackgroundTaskTail.Limits = .standard, read: @escaping @Sendable (Int) -> BackgroundTaskTail.Result,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.init(taskID: taskID, limits: limits, update: { window, _ in .replace(read(window), nil) }, pause: pause)
    }

    /// - update: 창 크기와 앞 읽기의 자리를 받아 바뀐 것만 돌려준다 (메인 밖에서 불린다)
    init(
        taskID: String, limits: BackgroundTaskTail.Limits = .standard, update: @escaping @Sendable (Int, BackgroundTaskTail.Cursor?) -> BackgroundTaskTail.Update,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.taskID = taskID
        self.limits = limits
        self.source = update
        self.pause = pause
        window = limits.tailBytes
    }

    /// 결과 → 화면 상태. 아직 없는 파일은 도는 일이면 "아직 출력 없음", 끝난 일이면 못 읽음 (지워졌다)
    static func state(for result: BackgroundTaskTail.Result, running: Bool) -> State {
        switch result {
        case .output(.text(let text, let earlier)): text.isEmpty ? .empty : .text(text, hasEarlier: earlier)
        case .output(.agent(let turns, let earlier)): turns.isEmpty ? .empty : .agent(turns, hasEarlier: earlier)
        case .missing: running ? .empty : .unavailable
        case .unreadable: .unavailable
        }
    }

    /// 열렸다: 한 번 읽고, 도는 일이면 1초마다 이어 읽는다. 이미 돌고 있으면 아무 일도 없다
    func start(isRunning: @escaping @MainActor () -> Bool) {
        self.isRunning = isRunning
        guard loop == nil else { return }
        stopped = false
        let pause = pause
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readOnce()
                guard let keepGoing = self?.stillRunning(), keepGoing else { return }
                await pause(Self.interval)
            }
        }
    }

    private func stillRunning() -> Bool { isRunning() }

    func stop() {
        loop?.cancel()
        loop = nil
        stopped = true
        generation += 1
    }

    var canLoadEarlier: Bool { window < limits.maxTailBytes }

    /// "Show earlier": 창을 넓혀 더 앞을 본다 (상한까지). 더 넓힐 수 없으면 아무 일도 없다
    func showEarlier() {
        guard window < limits.maxTailBytes else { return }
        window = min(window * Self.widening, limits.maxTailBytes)
        generation += 1
        Task { await readOnce() }
    }

    /// Try again
    func retry() {
        state = .loading
        generation += 1
        cursor = nil
        Task { await readOnce() }
    }

    /// 한 번 읽는다. 이미 읽는 중이면 그 읽기가 끝난 뒤 한 번 더 읽도록 맡기고 돌아온다 (읽기는 겹치지 않는다)
    func readOnce() async {
        guard !stopped else { return }
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        defer { reading = false }
        repeat {
            readAgain = false
            let started = generation
            let source = source
            let window = window
            let saved = cursor
            let update = await Task.detached(priority: .userInitiated) { source(window, saved) }.value
            guard !Task.isCancelled else { return }
            // 읽는 사이 창 · Try again · 멈춤이 바뀌었다: 낡은 결과는 버린다 (멈춘 것이면 다시 읽지 않고, 아니면 바뀐 값으로 다시 읽는다)
            guard started == generation else {
                readAgain = !stopped
                continue
            }
            apply(update)
        } while readAgain
    }

    private func apply(_ update: BackgroundTaskTail.Update) {
        switch update {
        case .unchanged:
            break
        case .replace(let result, let next):
            cursor = next
            if case .output(.agent(let turns, let earlier)) = result {
                agentTurns = turns
                agentEarlier = earlier
            } else {
                agentTurns = []
                agentEarlier = false
            }
            let value = Self.state(for: result, running: isRunning())
            if value != state { state = value }
        case .append(let turns, let next):
            cursor = next
            guard !turns.isEmpty else { return }
            agentTurns += turns
            if agentTurns.count > limits.maxTurns {
                agentTurns.removeFirst(agentTurns.count - limits.maxTurns)
                agentEarlier = true
            }
            state = .agent(agentTurns, hasEarlier: agentEarlier)
        }
    }

    deinit { loop?.cancel() }
}
#endif
