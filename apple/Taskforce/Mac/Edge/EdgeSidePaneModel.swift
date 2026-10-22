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
    /// 일 목록 (쓰는 쪽이 먹인다)
    var tasks = BackgroundTaskList()
    /// 패널 왼쪽 끝에서 화면 왼쪽 끝까지의 여유 (컨트롤러가 창 자리에서 잰다). 모르면 넉넉하다고 본다
    var room: CGFloat = .greatestFiniteMagnitude

    private(set) var expanded = false
    private(set) var selectedID: String?
    /// 이 세션의 목록을 마지막으로 열어 본 시각 (이 Mac에 저장)
    private(set) var openedAt: Date?
    /// 세션이 닫힌 때 (Claude에서 닫음): 그때까지 돌던 일은 Stopped다
    private(set) var closedAt: Date?
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

    /// 다른 세션으로 바뀌었다: 그 세션의 열어 본 시각을 읽고 접힌 채로 시작한다
    func attach(session key: String?) {
        guard key != sessionKey else { return }
        sessionKey = key
        openedAt = key.flatMap { store.openedAt(session: $0) }
        expanded = false
        dropTail()
        selectedID = nil
        closedAt = nil
        tasks = BackgroundTaskList()
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
    var windowExtra: CGFloat { plan.outside }

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

/// 한 일의 출력 꼬리 상태 (DZ v2 E10): 열려 있는 동안 1초마다 이어 읽는다 (도는 일만. 끝난 일은 한 번 읽고 멈춘다). 읽기는 메인 밖에서 한다. 글 · 경로를 로그에 남기지 않는다
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
    /// "Show earlier"가 창을 넓히는 배수 (16 KiB → 64 KiB → 256 KiB → 1 MiB)
    static let widening = 4

    private(set) var state = State.loading
    private(set) var window: Int
    let taskID: String
    @ObservationIgnored private let read: @Sendable (Int) -> BackgroundTaskTail.Result
    @ObservationIgnored private let limits: BackgroundTaskTail.Limits
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 그 일이 아직 도는가 (끝난 일은 한 번 읽고 멈춘다). 열 때 소유자가 준다
    @ObservationIgnored private var isRunning: @MainActor () -> Bool = { false }
    @ObservationIgnored private let pause: @Sendable (Duration) async -> Void

    /// - read: 창 크기(바이트)를 받아 그 일의 꼬리를 읽는다 (메인 밖에서 불린다)
    init(
        taskID: String, limits: BackgroundTaskTail.Limits = .standard, read: @escaping @Sendable (Int) -> BackgroundTaskTail.Result,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.taskID = taskID
        self.limits = limits
        self.read = read
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
    }

    /// "Show earlier": 창을 넓혀 더 앞을 본다 (상한까지). 더 넓힐 수 없으면 아무 일도 없다
    func showEarlier() {
        guard window < limits.maxTailBytes else { return }
        window = min(window * Self.widening, limits.maxTailBytes)
        Task { await readOnce() }
    }

    /// Try again
    func retry() {
        state = .loading
        Task { await readOnce() }
    }

    func readOnce() async {
        let read = read
        let window = window
        let result = await Task.detached(priority: .userInitiated) { read(window) }.value
        guard !Task.isCancelled else { return }
        let next = Self.state(for: result, running: isRunning())
        if next != state { state = next }
    }

    deinit { loop?.cancel() }
}
#endif
