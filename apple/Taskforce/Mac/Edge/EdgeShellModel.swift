#if os(macOS)
import Foundation
import Observation
import TaskforceKit
import TaskforceUI

/// 0.2.0 Edge 셸(EdgeRail + EdgePanel)을 켜는 플래그. 기본은 꺼짐 → 기존 ⌥Space 런처(`LauncherPanelController`).
/// 이 PR은 셸의 뼈대라 켜는 길은 격리된 Debug 실행뿐이다 (구현 계획 7장 플래그 경계):
/// - 앱: launch argument `-TF_EDGE_SHELL YES`만 (인자 영역. 저장된 defaults로는 켜지지 않는다)
/// - 테스트: 전용 UserDefaults suite를 넘긴다
/// Release 빌드는 늘 꺼짐이다. 실사용 켜기(출시 gate)는 그때 이 함수를 바꾼다.
enum EdgeShellFlag {
    static let key = "TF_EDGE_SHELL"

    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        if let defaults { return defaults.bool(forKey: key) }
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let value = arguments[key] else { return false }
        return (value as? Bool) ?? (value as? String).map { NSString(string: $0).boolValue } ?? false
        #else
        return false
        #endif
    }
}

/// 레일 · 패널이 읽는 지금의 일 (NowStore · RunStore에서 옮겨 담는다. 모델 테스트는 이 값을 직접 넣는다)
struct EdgeWorkSnapshot: Equatable {
    var review: [ActionSummary] = []
    /// In Progress · To Do (서버 순서)
    var open: [ActionSummary] = []
    var doneToday: [ActionSummary] = []
    /// 끝나지 않은 run이 있는 할 일
    var working: Set<UUID> = []
    /// 멈춤을 요청했고 아직 끝나지 않은 할 일
    var stopping: Set<UUID> = []
    var isLoaded = false

    static let empty = EdgeWorkSnapshot()

    init(review: [ActionSummary] = [], open: [ActionSummary] = [], doneToday: [ActionSummary] = [],
         working: Set<UUID> = [], stopping: Set<UUID> = [], isLoaded: Bool = false) {
        self.review = review
        self.open = open
        self.doneToday = doneToday
        self.working = working
        self.stopping = stopping
        self.isLoaded = isLoaded
    }

    init(sections: TaskSections, working: Set<UUID>, stopping: Set<UUID>, isLoaded: Bool) {
        self.init(
            review: sections.review, open: sections.inProgress.map(\.action) + sections.toDo.map(\.action),
            doneToday: sections.doneToday, working: working, stopping: stopping, isLoaded: isLoaded
        )
    }

    var isEmpty: Bool { review.isEmpty && open.isEmpty && doneToday.isEmpty }
}

/// 미루어 부르기 (호버 120ms · 떠남 400ms · Done 3초). 테스트는 손으로 돌리는 것을 넣는다
@MainActor
final class EdgeTimer {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

typealias EdgeSchedule = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> EdgeTimer

@MainActor
enum EdgeScheduler {
    static let live: EdgeSchedule = { delay, work in
        let timer = EdgeTimer()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !timer.isCancelled { work() }
        }
        return timer
    }
}

/// Edge 셸의 상태: 레일이 숨었나 · 펼쳤나 · 가는 줄(idle)인가, 패널이 열렸나 · 무엇을 보이나, 레일의 칸.
/// 창 · 이벤트는 `EdgeShellController`가 맡고, 이 모델은 시간과 입력을 받아 상태만 바꾼다 (테스트로 고정).
@MainActor
@Observable
final class EdgeShellModel {
    /// 패널이 보이는 것 (한 번에 하나). Review · 일 상세 · 대화는 다음 PR(S3 · S4 · B3)에서 더한다
    enum View: String, CaseIterable {
        case allWork, chats

        var title: String {
            switch self {
            case .allWork: "All work"
            case .chats: "Chats"
            }
        }
    }

    /// 레일의 고정 칸
    enum Control: String, CaseIterable {
        case allWork, chats, more

        var label: String {
            switch self {
            case .allWork: "All work"
            case .chats: "Chats"
            case .more: "More"
            }
        }

        /// 툴팁의 단축키 (More는 없음)
        var shortcut: String? {
            switch self {
            case .allWork: "⌘2"
            case .chats: "⌘3"
            case .more: nil
            }
        }
    }

    private(set) var slots: [RailEntry] = []
    /// 노치에 120ms 머물러 펼친 레일 (패널이 열려 있으면 `isExpanded`가 따로 참)
    private(set) var railHovered = false
    private(set) var panelOpen = false
    private(set) var view: View = .allWork
    /// 레일에서 연 일 (패널 목록에서 그 행을 표시)
    private(set) var currentID: UUID?
    /// 포인터 아래의 레일 칸. 패널이 닫혀 있으면 툴팁, 열려 있으면 패널의 그 행을 표시한다
    private(set) var hoveredID: UUID?
    private(set) var hoveredControl: Control?
    private(set) var menuOpen = false
    private(set) var work = EdgeWorkSnapshot.empty
    /// 레일에 오를 수 있는 일 전부 (칸은 넷까지지만 접근성 이름의 개수는 전부를 센다)
    private(set) var live: [RailEntry] = []
    /// 움직임 줄이기 (시스템 설정 · Debug 스냅샷의 `-TFReduceMotion YES`)
    var reduceMotion: Bool

    @ObservationIgnored private let schedule: EdgeSchedule
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var enterTimer: EdgeTimer?
    @ObservationIgnored private var leaveTimer: EdgeTimer?
    @ObservationIgnored private var doneTimer: EdgeTimer?
    @ObservationIgnored private var pointerInside = false
    /// 레일에서 막 끝난 일 → 끝난 시각 (3초 동안 Done 링)
    @ObservationIgnored private var recentlyDone: [UUID: Date] = [:]

    init(reduceMotion: Bool = false, schedule: @escaping EdgeSchedule = EdgeScheduler.live, clock: @escaping () -> Date = Date.init) {
        self.reduceMotion = reduceMotion
        self.schedule = schedule
        self.clock = clock
    }

    // MARK: 레일 모양

    /// 펼친 레일: 노치 호버 · 열린 패널(패널 옆 레일은 늘 펼친다)
    var isExpanded: Bool { railHovered || panelOpen }
    /// 숨은 레일의 노치에 보이는 링 (셋까지)
    var notch: [RailEntry] { RailOrdering.notch(slots) }
    /// 펼쳤을 때만 보이는 나머지 일
    var rest: [RailEntry] { Array(slots.dropFirst(notch.count)) }
    /// 보일 링도 없고 펼치지도 않음: 6 × 36pt 가는 줄 (그래도 호버 대상)
    var isIdle: Bool { notch.isEmpty && !isExpanded }
    var railAccessibilityLabel: String { RailOrdering.accessibilityLabel(live) }

    /// 레일 툴팁 ("Title · State · Activity", 고정 칸은 "All work ⌘2"). 패널이 열리면 끈다
    var tooltip: (title: String, detail: String)? {
        guard isExpanded, !panelOpen, !menuOpen else { return nil }
        if let hoveredID, let entry = slots.first(where: { $0.id == hoveredID }) {
            return (entry.title, "· \(entry.state.label) · \(entry.activity)")
        }
        if let hoveredControl, let shortcut = hoveredControl.shortcut {
            return (hoveredControl.label, shortcut)
        }
        return nil
    }

    // MARK: 포인터

    /// 포인터가 레일 모양 안에 들어옴 · 나감. 들어와 120ms 머물면 펼치고, 나가 400ms 뒤 숨는다 (패널이 열려 있으면 숨지 않는다)
    func pointer(inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside {
            leaveTimer?.cancel()
            leaveTimer = nil
            guard !railHovered, enterTimer == nil else { return }
            enterTimer = schedule(TFMotion.railHoverDelay) { [weak self] in
                guard let self else { return }
                self.enterTimer = nil
                if self.pointerInside { self.railHovered = true }
            }
        } else {
            enterTimer?.cancel()
            enterTimer = nil
            hoveredID = nil
            hoveredControl = nil
            guard railHovered, leaveTimer == nil else { return }
            leaveTimer = schedule(TFMotion.railLeaveDelay) { [weak self] in
                guard let self else { return }
                self.leaveTimer = nil
                if !self.pointerInside, !self.menuOpen { self.railHovered = false }
            }
        }
    }

    func hover(item id: UUID?) {
        hoveredID = id
        if id != nil { hoveredControl = nil }
    }

    func hover(control: Control?) {
        hoveredControl = control
        if control != nil { hoveredID = nil }
    }

    // MARK: 패널

    /// ⌥ Space: 열려 있으면 접고, 아니면 마지막에 본 것을 연다 (Review가 생기면 S4에서 newest Review 먼저)
    func togglePanel() {
        if panelOpen {
            dismiss()
        } else {
            openPanel(view)
        }
    }

    func openPanel(_ view: View) {
        self.view = view
        panelOpen = true
        menuOpen = false
    }

    /// All work: 레일의 All work · ⌘2. 고른 행 · 필터를 비운다
    func openAllWork() {
        currentID = nil
        openPanel(.allWork)
    }

    /// Chats: 레일의 Chats · ⌘3 (마지막 대화. 대화는 B3)
    func openChats() {
        openPanel(.chats)
    }

    /// 레일의 일: 그 일을 연다. 일 상세 · Review 화면은 다음 PR이라 지금은 All work에서 그 행을 표시한다
    func open(itemID: UUID) {
        currentID = itemID
        openPanel(.allWork)
    }

    /// 밖 클릭(클릭은 누른 곳으로도 그대로 간다) · Esc · ⌥ Space. 접어도 일은 멈추지 않고 초안은 남는다
    func dismiss() {
        guard panelOpen else { return }
        panelOpen = false
        // 포인터가 레일에 없으면 바로 숨는다 (호버로 펼친 상태가 아니었으면)
        if !pointerInside {
            railHovered = false
        }
    }

    // MARK: More 메뉴

    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        if !open, !pointerInside, !panelOpen {
            railHovered = false
        }
    }

    // MARK: 데이터

    /// 목록 · run이 바뀔 때마다. 레일의 칸은 남아 있는 일의 순서를 지킨다 (`RailOrdering`)
    func update(_ work: EdgeWorkSnapshot) {
        let now = clock()
        let wasOnRail = Set(slots.filter { $0.kind != .done }.map(\.id))
        let doneIDs = Set(work.doneToday.map(\.id))
        let liveIDs = Set(work.review.map(\.id)).union(work.working)
        // 레일에 있던 일이 지금 끝남 → 3초 동안 Done
        for id in wasOnRail where doneIDs.contains(id) && !liveIDs.contains(id) && recentlyDone[id] == nil {
            recentlyDone[id] = now
        }
        self.work = work
        refreshSlots(at: now)
    }

    /// Done 3초가 지난 일을 뺀다
    func expireDone() {
        refreshSlots(at: clock())
    }

    private func refreshSlots(at now: Date) {
        recentlyDone = recentlyDone.filter { now.timeIntervalSince($0.value) < TFMotion.doneHold }
        let entries = Self.entries(work, recentlyDone: recentlyDone)
        live = entries
        slots = RailOrdering.slots(previous: slots.map(\.id), entries: entries)
        if let hoveredID, !slots.contains(where: { $0.id == hoveredID }) { self.hoveredID = nil }
        scheduleDoneExpiry(now: now)
    }

    private func scheduleDoneExpiry(now: Date) {
        doneTimer?.cancel()
        doneTimer = nil
        guard let earliest = recentlyDone.values.min() else { return }
        let delay = max(0, TFMotion.doneHold - now.timeIntervalSince(earliest))
        doneTimer = schedule(delay) { [weak self] in self?.expireDone() }
    }

    /// 지금 레일에 오를 수 있는 일: 확인 요청(needs you) · run이 도는 일(running · stop requested) · 막 끝난 일(done)
    static func entries(_ work: EdgeWorkSnapshot, recentlyDone: [UUID: Date]) -> [RailEntry] {
        var entries = work.review.map {
            RailEntry(id: $0.id, title: $0.title, kind: .needsYou, state: TaskStatusMark.State(.review))
        }
        let reviewIDs = Set(entries.map(\.id))
        for action in work.open where work.working.contains(action.id) && !reviewIDs.contains(action.id) {
            let kind: ActivityRing.Kind = work.stopping.contains(action.id) ? .stopping : .running
            let activity = kind == .stopping ? "Stop requested · not confirmed" : nil
            entries.append(RailEntry(id: action.id, title: action.title, kind: kind, state: TaskStatusMark.State(TaskGroup.open(action)), activity: activity))
        }
        for action in work.doneToday where recentlyDone[action.id] != nil {
            entries.append(RailEntry(id: action.id, title: action.title, kind: .done, state: .done))
        }
        return entries
    }
}
#endif
