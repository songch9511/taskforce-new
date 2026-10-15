#if os(macOS)
import AppKit
import Foundation
import Observation
import TaskforceKit
import TaskforceUI

/// 0.2.0 Edge 셸(EdgeRail + EdgePanel)을 켜는 플래그. 기본은 꺼짐 → 기존 ⌥Space 런처(`LauncherPanelController`).
/// 이 PR은 셸의 뼈대라 켜는 길은 격리된 Debug 실행뿐이다 (구현 계획 7장 플래그 경계):
/// - 앱: launch argument `-TF_EDGE_SHELL YES`만 (인자 영역. 저장된 defaults로는 켜지지 않는다)
/// - 테스트: 전용 UserDefaults suite를 넘긴다
/// Release 빌드는 `EdgeSurfaces.release`를 따른다: Edge 셸은 켜진다 (⌥ Space는 Edge 패널을 연다). DEBUG는 위 인자 그대로.
enum EdgeShellFlag {
    static let key = "TF_EDGE_SHELL"

    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).shell
        #else
        return EdgeSurfaces.release.shell
        #endif
    }
}

/// 0.2.0 S3b(범위 멤버십 · ProjectLink)를 켜는 플래그. **기본은 꺼짐** → All work는 S3 그대로다:
/// 실제 앱 생성 경로(`AppRuntime.makeChatRuntime`)가 범위 멤버십 게이트웨이 · 저장소를 아예 만들지 않아 RLS 멤버십 읽기 · 멤버십 쓰기 · ProjectLink 연결이 없고,
/// 모든 할 일은 Ungrouped이며 검색 · 필터는 기존 그대로다. B3 Chats · Remembered와 Edge 셸은 그대로 유지된다.
/// (`TF_EDGE_SHELL`을 끄면 구 런처로 돌아가는 것이지 S3로 돌아가는 것이 아니다: 두 플래그는 다른 축이다. 서버 `MEMORY_ENABLED`도 POST만 막는 또 다른 축이다.)
/// - 앱: launch argument `-TF_S3B YES`만 (인자 영역. 저장된 defaults로는 켜지지 않는다). `TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 뜻이 있다
/// - 테스트: 전용 UserDefaults suite를 넘긴다
/// Release 빌드는 늘 꺼짐이다 (`EdgeSurfaces.release.projects`, Chats 런타임이 없어 범위 멤버십도 없다).
enum S3bFlag {
    static let key = "TF_S3B"

    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).projects
        #else
        return EdgeSurfaces.release.projects
        #endif
    }
}

/// 0.2.0 S4(Mac Review 페이지)를 켜는 플래그. **기본은 꺼짐** → Review 페이지 · ⌘1 · ← → · 1 · 2 연결이 만들어지지 않고 지금(S3b/B3/Edge) 그대로다:
/// 실제 앱 생성 경로(`AppRuntime.reviewDesk`)가 `ReviewDesk`를 아예 만들지 않아 `EdgeShellModel.review == nil`이다. 확인 요청은 All work의 줄로만 보이고,
/// 레일의 Needs-you 링은 All work에서 그 행을 표시하며, 단축키는 ⌘2 · ⌘3 · ⌘N · Esc뿐이다.
/// (`TF_EDGE_SHELL`을 끄면 구 런처로 돌아가는 것이지 S4만 끄는 것이 아니다: 두 플래그는 다른 축이다.)
/// - 앱: launch argument `-TF_S4 YES`만 (인자 영역. 저장된 defaults로는 켜지지 않는다). `TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 뜻이 있다
/// - 테스트: 전용 UserDefaults suite를 넘긴다
/// Release 빌드는 켜진다 (`EdgeSurfaces.release.review`): confirm 요청에 Confirm · Dismiss, 기존 v1 경로.
enum S4Flag {
    static let key = "TF_S4"

    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).review
        #else
        return EdgeSurfaces.release.review
        #endif
    }
}

/// 0.2.0 C3(All work 위 ReturnSummary)를 켜는 플래그. **기본은 꺼짐** → All work는 지금(S4/S3b/B3/Edge) 그대로다:
/// 실제 앱 생성 경로(`AppRuntime.returnSummary`)가 `ReturnSummaryStore`를 아예 만들지 않아 `EdgeShellModel.summary == nil`이고, 서버 `/api/v2/return-summary`를 읽지도 않으며
/// 목록 위 카드 자리(`WorkList.summary`)가 비어 있다. Review(S4) · 프로젝트 묶음(S3b) · Chats(B3)는 각자의 플래그를 따른다.
/// (`TF_EDGE_SHELL`을 끄면 구 런처로 돌아가는 것이지 C3만 끄는 것이 아니다: 플래그는 서로 다른 축이다. 서버 `REVIEW_V2_ENABLED`도 또 다른 축이다 — 서버가 꺼져 있으면 404로 읽어 아무것도 보이지 않는다.)
/// - 앱: launch argument `-TF_C3 YES`만 (인자 영역. 저장된 defaults로는 켜지지 않는다). `TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 뜻이 있다
/// - 테스트: 전용 UserDefaults suite를 넘긴다
/// Release 빌드는 켜진다 (`EdgeSurfaces.release.summary`): 서버 gate가 꺼져 있으면 404로 조용히 사라진다.
enum C3Flag {
    static let key = "TF_C3"

    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).summary
        #else
        return EdgeSurfaces.release.summary
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
    /// 열린 할 일의 서버 순서 이유 (기한 빨강)
    var reasons: [UUID: [RankReason]] = [:]
    /// 목록을 보일 수 있는 상태 (읽는 중 · 받음 · 오프라인 · 실패)
    var load: WorkLoad = .loading
    /// Done today를 읽은 기기 시간대의 그날 0시 (`NowStore.doneTodaySince`)
    var doneSince: Date?
    /// 할 일 없음 화면에 Connect a source를 보일지 (연결을 읽었고 연결된 원문이 없을 때)
    var canConnect = false
    /// 연결 중 하나라도 동기화 중 (`AccountStore.anySyncing`): 빈 목록이어도 할 일 없음을 말하지 않는다
    var syncing = false

    static let empty = EdgeWorkSnapshot()

    init(review: [ActionSummary] = [], open: [ActionSummary] = [], doneToday: [ActionSummary] = [],
         working: Set<UUID> = [], stopping: Set<UUID> = [], reasons: [UUID: [RankReason]] = [:],
         load: WorkLoad = .loading, doneSince: Date? = nil, canConnect: Bool = false, syncing: Bool = false) {
        self.review = review
        self.open = open
        self.doneToday = doneToday
        self.working = working
        self.stopping = stopping
        self.reasons = reasons
        self.load = load
        self.doneSince = doneSince
        self.canConnect = canConnect
        self.syncing = syncing
    }

    init(
        sections: TaskSections, working: Set<UUID>, stopping: Set<UUID>, load: WorkLoad, doneSince: Date?, canConnect: Bool, syncing: Bool = false
    ) {
        let open = sections.inProgress + sections.toDo
        self.init(
            review: sections.review, open: open.map(\.action), doneToday: sections.doneToday, working: working, stopping: stopping,
            reasons: Dictionary(open.map { ($0.id, $0.reasons) }, uniquingKeysWith: { first, _ in first }),
            load: load, doneSince: doneSince, canConnect: canConnect, syncing: syncing
        )
    }

    var isEmpty: Bool { review.isEmpty && open.isEmpty && doneToday.isEmpty }

    /// Connect a source를 보일지: 연결을 읽었고 active 연결이 하나도 없을 때만 (아직 모르면 보이지 않는다)
    static func canConnect(connectionsLoaded: Bool, connections: [ConnectionRecord]) -> Bool {
        connectionsLoaded && !connections.contains { $0.status == .active }
    }

    /// All work의 줄 (`WorkItem.list`). Done today는 읽은 날이 기기 시간대의 오늘일 때만 (자정 · 시간대가 바뀌면 다시 읽을 때까지 없음).
    /// `memberships`: 실제 범위 멤버십 (S3b). 줄의 상태 · 활동 · 수행자 · 순서는 멤버십과 상관없다
    func items(now: Date, calendar: Calendar = .current, memberships: WorkMembershipIndex = .empty, numbers: [UUID: Int] = [:]) -> [WorkItem] {
        let done = DoneTodayWindow.isCurrent(since: doneSince, now: now, calendar: calendar) ? doneToday : []
        return WorkItem.list(
            reviews: review, open: open, doneToday: done, working: working, stopping: stopping, reasons: reasons, memberships: memberships, numbers: numbers
        )
    }
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
    /// 패널이 보이는 것 (한 번에 하나). `review`는 S4 gate가 켜졌을 때만 열린다 (`review != nil`). 일 상세는 다음 PR에서 더한다
    enum View: String, CaseIterable {
        case allWork, chats, review

        /// 패널 머리 제목. All work 화면의 머리는 "Your work"다 (디자인 WorkPage · WorkList 견본). 레일 칸 이름은 그대로 All work.
        /// Review의 머리는 그 결정의 항목 이름이다 (디자인 PanelHeader "Launch timing"): 이 값은 항목이 없을 때(빈 · 읽는 중 · 오프라인)의 머리다
        var title: String {
            switch self {
            case .allWork: "Your work"
            case .chats: "Chats"
            case .review: "Review"
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

    /// 이 셸의 레일 고정 칸 (Chats가 꺼져 있으면 Chats 칸이 없다)
    var controls: [Control] {
        chatsEnabled ? Control.allCases : Control.allCases.filter { $0 != .chats }
    }

    /// 고정 칸의 이름. 새 Issues 화면이 켜진 셸의 첫 칸은 "Issues"다 (툴팁 "Issues ⌘2", OA U2 사용자 결정): 꺼져 있으면 "All work"
    func label(for control: Control) -> String {
        control == .allWork && issues != nil ? Self.issuesLabel : control.label
    }

    static let issuesLabel = "Issues"
    static let newSessionLabel = "New session"

    /// 이 셸이 듣는 키 명령인가: Chats가 꺼져 있으면 ⌘3 · ⌘N은 연결이 없어 지나간다 (먹지 않는다)
    func listens(to command: EdgeKeyCommand) -> Bool {
        switch command {
        case .chats, .newChat: chatsEnabled
        case .escape, .review, .allWork: true
        }
    }

    private(set) var slots: [RailEntry] = []
    /// 노치에 120ms 머물러 펼친 레일 (패널이 열려 있으면 `isExpanded`가 따로 참)
    private(set) var railHovered = false
    private(set) var panelOpen = false {
        // 패널을 접으면 세션 패널의 대화 읽기 기록을 지운다: 접어 둔 사이 온라인 복귀 · 목록 새로 읽기가 그 대화의 캐시를 비웠을 수 있어
        // 복원(⌥Space)하면 같은 conversation id여도 다시 읽는다 (재검토 반영 1)
        didSet { if !panelOpen { loadedPanelConversation = nil } }
    }
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

    // All work (S3): 검색어 · 필터 · 열린 필터 · 고정. 계정이 바뀌면 비우고, 레일의 All work(⌘2)로 열면 검색어 · 필터를 비운다
    private(set) var workFilter = WorkFilter()
    private(set) var filtersOpen = false
    /// 지금 계정의 고정 (셋까지, `pinStore`에 계정별로 둔다)
    private(set) var pins = WorkPins()
    /// 지금 로그인한 계정 (고정을 읽고 쓰는 기준). 로그아웃이면 nil
    private(set) var account: UUID?
    /// 로컬 날짜 · 시간대 · 시스템 시계가 바뀌었을 수 있다는 신호 (`timeChanged()`, 컨트롤러의 `EdgeTimeWatcher`가 올린다).
    /// `workItems`가 읽어서, 자정 · 시간대 변경 뒤에도 열린 채인 패널이 다시 계산한다. 값 자체에는 뜻이 없다
    private(set) var timeEpoch = 0
    /// All work의 버튼이 가는 곳 (컨트롤러가 채운다): Add task = 기존 런처(직접 추가의 정식 입구) · Connect a source = 설정 Connections ·
    /// Try again = 목록 다시 읽기
    @ObservationIgnored var onAddTask: () -> Void = {}
    @ObservationIgnored var onConnect: () -> Void = {}
    @ObservationIgnored var onRetry: () -> Void = {}
    /// Chats (B3): 패널이 Chats로 열릴 때 (⌘3 · ⌥ Space로 마지막 화면 · 레일) 마지막 대화를 되살린다 · ⌘N은 새 대화 · Esc는 목록에서 대화로 먼저
    @ObservationIgnored var onChatsOpened: () -> Void = {}
    @ObservationIgnored var onNewChat: () -> Void = {}
    @ObservationIgnored var onChatEscape: () -> Bool = { false }
    /// 실제 범위(프로젝트) 멤버십 (S3b). 없으면 모든 할 일이 Ungrouped (범위를 읽지 않는다)
    let contexts: WorkContextStore?
    /// Review(S4)의 답을 보내는 곳. **없으면 S4 gate가 꺼진 것이다**: Review 페이지 · 단축키 연결이 없다 (`S4Flag`)
    let review: ReviewDesk?
    /// 복귀 요약(C3)을 읽고 Clear하는 곳. **없으면 C3 gate가 꺼진 것이다**: All work 위 카드가 없고 서버를 읽지 않는다 (`C3Flag`)
    let summary: ReturnSummaryStore?
    /// Chats(B3)가 이 셸에 있는가 (`ChatsFlag`, 컨트롤러는 `ChatRuntime`이 있을 때만 켠다). **꺼져 있으면(Release) Chats는 아무 데도 없다**: 레일 Chats 칸 · ⌘3 · ⌘N · `.chats` 화면이 없고
    /// `openChats` · `newChat` · `openPanel(.chats)`는 아무것도 하지 않는다 (대화 읽기 · 기억 · 연결 복귀 읽기도 만들어지지 않는다)
    let chatsEnabled: Bool
    /// Assistant 창(OA U1)이 이 셸에 있는가 (`EdgeSurfaces.assistantWindows`, 컨트롤러가 정한다). 켜져 있으면 레일 Chats · ⌘3 · ⌘N은 **패널이 아니라 창**을 열고 앞으로 가져온다:
    /// 패널은 Chats 화면을 열지 않는다 (`View.chats`에 들어가지 않는다). 꺼져 있으면(`chatsEnabled`만 켜진 옛 구성) 지금 그대로 패널의 Chats다
    let windowsEnabled: Bool
    /// 창을 열거나 앞으로 (⌘3 · 레일 Chats) · 새 창 (⌘N): 컨트롤러의 창 관리자가 채운다
    @ObservationIgnored var onChats: () -> Void = {}
    @ObservationIgnored var onNewWindow: () -> Void = {}
    /// Assistant 창이 앞에 있다 (레일 Chats 칸이 `bezel/hover`로 칠해진다). 창 관리자가 올린다
    var assistantWindowFront = false
    /// 새 Issues 화면(OA U2): 세션 · 번호 · 상세를 읽는 곳. **없으면 게이트가 꺼진 것이다** — Projects · 이슈 목록 · 상세 · SessionTab · 세션 패널이 없고 All work는 지금 그대로다 (`EdgeSurfaces.issueScreens`)
    let issues: IssueRuntime?
    var issueScreensEnabled: Bool { issues != nil }
    /// Issues 패널 안의 화면 이동 (Projects → 목록 → 상세). 게이트가 켜졌을 때 `View.allWork`가 이 화면을 보인다
    private(set) var nav = IssueNavigation()
    /// 열린 세션 패널의 세션 (이슈 패널 왼쪽의 두 번째 패널). 이슈 패널 없이 열리지 않는다. 패널을 접어도 남아 ⌥ Space로 다시 열면 둘 다 마지막 화면이다
    private(set) var sessionPanelID: UUID? {
        didSet { if sessionPanelID == nil { loadedPanelConversation = nil } }
    }
    /// 세션 패널이 마지막으로 읽도록 한 대화 (패널을 닫으면 지운다: 다시 열면 다시 읽는다)
    @ObservationIgnored private var loadedPanelConversation: UUID?
    /// 세션 패널이 보이는 대화를 읽는다 (열 때 · 패널의 conversation id가 바뀔 때): 컨트롤러가 `ChatStore.loadConversation`에 잇는다 (id로 직접 읽고 오류 · 다시 시도를 보인다)
    @ObservationIgnored var onLoadSessionConversation: (UUID) -> Void = { _ in }
    #if DEBUG
    /// 디자인 비교 스냅샷(`-TFEdgeSnapshotIssues`)만: SessionTab을 호버한 모양(펼침)으로 둔다
    var tabExpandedForSnapshot = false
    #endif
    /// New session `+`가 눌렸다: 창 관리자가 새 Assistant 창을 열고 범위 칩을 달아 대상 메뉴를 연다 (칩은 눌린 곳의 범위)
    @ObservationIgnored var onNewSession: (AssistantOpenItem?) -> Void = { _ in }
    /// Ask 알약: 앞 Assistant 창에 그 항목의 칩을 더한다 (창이 없으면 새 창). 컨트롤러가 창 관리자에 잇는다
    @ObservationIgnored var onAsk: (AssistantOpenItem) -> Void = { _ in }
    /// 인용의 원문 링크를 연다 (시험은 가짜로 바꾼다)
    @ObservationIgnored var onOpenURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 세션 머리 알약(Open in Terminal · Resume here)의 동작. **없으면 알약을 그리지 않는다** (알약 동작은 D4a: 앱에서는 비어 있고 견본 하네스만 채운다)
    @ObservationIgnored var onSessionPill: ((AgentSessionPill, AgentSessionItem) -> Void)?
    /// More 목록(탭의 `…`): 숨은 세션들을 메뉴로 보인다. 컨트롤러가 메뉴 창을 올린다
    @ObservationIgnored var onShowMoreSessions: ([AgentSessionItem]) -> Void = { _ in }
    /// 포인터가 Review 타일 위에 있다 (툴팁 · 호버 덧칠)
    private(set) var hoveredTile = false
    /// 포인터가 New session `+` 위에 있다 (OA U2, 툴팁 · 호버 덧칠)
    private(set) var hoveredPlus = false
    /// Review 페이지가 보이는 결정의 stable action id. 몇 번째인지(index)가 아니라 id로 가리킨다: 큐가 바뀌어도 키 · 클릭은 이 id의 항목에만 간다
    private(set) var reviewID: UUID?
    /// Review 페이지에 들어온 차례: 패널을 다시 열거나 다른 화면에서 Review로 들어올 때마다 오른다 (단계를 옮기는 것은 아니다).
    /// 근거가 같은 방문 안에서는 다시 읽지 않고, 다시 들어오면 항목의 활동 시각과 상관없이 다시 확인한다 (`ReviewDesk.loadSource`)
    private(set) var reviewPresentation = 0
    /// All work 화면에 들어온 **방문**의 소유 번호 (C3): 패널을 닫았다 다시 열거나 다른 화면(Chats · Review)에서 All work로 돌아올 때마다 오른다.
    /// 같은 방문 안의 움직임(⌘2를 한 번 더 · 줄 열기 · 필터)은 올리지 않는다. Clear를 **받은 방문**에서만 보내려고 쓴다 (`clearSummary`, S4 `reviewPresentation`과 같은 방식):
    /// "지금 All work가 보이는가"만으로는 앞 방문에서 받은 선택이 다음 방문에서 나가는 것을 막지 못한다
    private(set) var allWorkPresentation = 0

    @ObservationIgnored private let schedule: EdgeSchedule
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let pinStore: WorkPinStore
    @ObservationIgnored private var enterTimer: EdgeTimer?
    @ObservationIgnored private var leaveTimer: EdgeTimer?
    @ObservationIgnored private var doneTimer: EdgeTimer?
    @ObservationIgnored private var pointerInside = false
    /// 레일에서 막 끝난 일 → 끝난 시각 (3초 동안 Done 링)
    @ObservationIgnored private var recentlyDone: [UUID: Date] = [:]

    /// - calendar: Done today가 오늘인지 가를 달력 · 시간대 (`NowStore`가 읽은 날을 적는 `Calendar.current`와 같다)
    /// - pinStore: 고정 저장 (앱은 전용 suite, 테스트 · 견본은 메모리)
    init(
        reduceMotion: Bool = false, schedule: @escaping EdgeSchedule = EdgeScheduler.live, clock: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { Calendar.current }, pinStore: WorkPinStore = WorkPinStore(defaults: nil),
        contexts: WorkContextStore? = nil, review: ReviewDesk? = nil, summary: ReturnSummaryStore? = nil, chatsEnabled: Bool = true,
        windowsEnabled: Bool = false, issues: IssueRuntime? = nil
    ) {
        self.issues = issues
        self.windowsEnabled = chatsEnabled && windowsEnabled
        self.contexts = contexts
        self.review = review
        self.summary = summary
        self.chatsEnabled = chatsEnabled
        self.reduceMotion = reduceMotion
        self.schedule = schedule
        self.clock = clock
        self.calendar = calendar
        self.pinStore = pinStore
        // 읽기가 반영돼 그 응답이 화면에 보일 수 있게 되는 그 자리에서 첫 정상 표시 확정을 받는다 (C)
        summary?.onDisplayed = { [weak self] in self?.considerSummaryBaseline() }
    }

    // MARK: 레일 모양

    /// 펼친 레일: 노치 호버 · 열린 패널(패널 옆 레일은 늘 펼친다)
    var isExpanded: Bool { railHovered || panelOpen }
    /// 숨은 레일의 노치에 보이는 링 (셋까지)
    var notch: [RailEntry] { RailOrdering.notch(slots) }
    /// 펼쳤을 때만 보이는 나머지 일
    var rest: [RailEntry] { Array(slots.dropFirst(notch.count)) }
    /// 보일 링도 없고 펼치지도 않음: 6 × 36pt 가는 줄 (그래도 호버 대상)
    var isIdle: Bool { notch.isEmpty && !isExpanded && reviewTileContent == nil }
    var railAccessibilityLabel: String { RailOrdering.accessibilityLabel(live) }

    /// 레일 툴팁 ("Title · State · Activity", 고정 칸은 "All work ⌘2"). 패널이 열리면 끈다
    var tooltip: (title: String, detail: String)? {
        guard isExpanded, !panelOpen, !menuOpen else { return nil }
        if hoveredTile, let tileTooltip { return tileTooltip }
        if hoveredPlus { return (Self.newSessionLabel, "") }
        if let hoveredID, let entry = slots.first(where: { $0.id == hoveredID }) {
            return (entry.title, "· \(entry.state.label) · \(entry.activity)")
        }
        if let hoveredControl, let shortcut = hoveredControl.shortcut {
            return (label(for: hoveredControl), shortcut)
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
            hoveredTile = false
            hoveredPlus = false
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
        if id != nil {
            hoveredControl = nil
            hoveredTile = false
            hoveredPlus = false
        }
    }

    func hover(control: Control?) {
        hoveredControl = control
        if control != nil {
            hoveredID = nil
            hoveredTile = false
            hoveredPlus = false
        }
    }

    /// 포인터가 Review 타일 위에 있다
    func hover(tile: Bool) {
        hoveredTile = tile
        if tile {
            hoveredID = nil
            hoveredControl = nil
            hoveredPlus = false
        }
    }

    /// 포인터가 New session `+` 위에 있다 (OA U2)
    func hover(plus: Bool) {
        hoveredPlus = plus
        if plus {
            hoveredID = nil
            hoveredControl = nil
            hoveredTile = false
        }
    }

    // MARK: Review 타일 (OA U1)

    /// 레일 맨 위 타일이 보일 것: needs-you(지금 Review 큐) → changes(복귀 요약의 읽음 처리할 변화) → 없음. 타일은 Review(S4)와 복귀 요약(C3)이 둘 다 켜졌을 때만 있다
    var reviewTileContent: ReviewTileContent? {
        ReviewTileRules.content(reviewCount: reviewQueue.count, summary: summary?.summary, reviewEnabled: review != nil, summaryEnabled: summary != nil)
    }

    /// 툴팁: "Review · Needs your answer" / "Review · Changes since 6:40 PM" (앞 낱말은 굵게, 나머지는 보조색)
    var tileTooltip: (title: String, detail: String)? {
        guard let content = reviewTileContent else { return nil }
        let text = ReviewTileRules.tooltip(content, now: clock(), calendar: calendar())
        guard let separator = text.range(of: " · ") else { return (text, "") }
        return (String(text[..<separator.lowerBound]), "· " + text[separator.upperBound...])
    }

    var tileAccessibilityName: String? {
        reviewTileContent.map { ReviewTileRules.accessibilityName($0, now: clock(), calendar: calendar()) }
    }

    /// Open 링: 타일이 데려가는 화면이 보이는 동안 (needs-you는 Review, changes는 복귀 요약이 있는 All work). 열기는 어떤 답도 아니다
    var tileOpen: Bool {
        guard panelOpen, let content = reviewTileContent else { return false }
        switch ReviewTileRules.destination(for: content) {
        case .newestReview: return view == .review
        case .returnSummary: return view == .allWork
        }
    }

    /// 타일을 누름: 기다리는 것이 있으면 가장 새 Review 항목, 변화만 있으면 복귀 요약. 타일이 없으면 아무 일도 없다 (목록 화면 `ReviewList`는 D4b-m)
    func openReviewTile() {
        guard let content = reviewTileContent else { return }
        switch ReviewTileRules.destination(for: content) {
        case .newestReview: openNewestReview()
        case .returnSummary: openAllWork()
        }
    }

    /// 패널에서 지금 열린 항목 (Assistant 창의 auto 칩이 따라간다): All work에서 연 일 · Review가 보이는 결정. 패널이 닫혀 있으면 없다.
    /// 새 Issues 화면이 켜져 있으면 가장 안쪽에 열린 것이다 (세션 패널 → 그 세션, 이슈 상세 → 그 이슈(번호 앞), 프로젝트 목록 → 그 프로젝트, 그 밖은 없음)
    var openItem: AssistantOpenItem? {
        guard panelOpen else { return nil }
        switch view {
        case .review:
            return shownReview.map { AssistantOpenItem(kind: .action, id: $0.id, title: $0.title, number: issues?.numbers.number(for: $0.id)) }
        case .allWork:
            if issues != nil {
                return IssueOpenItemRules.openItem(
                    screen: nav.current, session: openSessionItem, items: workItems, contexts: contextList,
                    number: { [issues] in issues?.numbers.number(for: $0) }
                )
            }
            guard let currentID, let item = workItems.first(where: { $0.id == currentID }) else { return nil }
            return AssistantOpenItem(kind: .action, id: currentID, title: item.action.title)
        case .chats:
            return nil
        }
    }

    // MARK: 패널

    /// ⌥ Space: 열려 있으면 접고, 아니면 **가장 새 Review 항목**, 기다리는 결정이 없으면 마지막에 본 화면을 연다 (DS Behaviors › Review: "⌥ Space opens the newest Review item, or the last view when nothing waits").
    /// 열기는 어떤 답도 아니다 (Review가 꺼진 셸은 결정을 열 수 없다)
    func togglePanel() {
        if panelOpen {
            dismiss()
        } else if review != nil, reviewQueue.newest != nil {
            openNewestReview()
        } else {
            openPanel(view)
        }
    }

    func openPanel(_ view: View) {
        // Chats가 없는 셸은 Chats 화면으로 열지 않는다 (⌥ Space의 마지막 화면 · 레일 · 키 어느 길로도). Assistant 창이 있는 셸도 패널은 Chats 화면을 열지 않는다
        guard view != .chats || (chatsEnabled && !windowsEnabled) else { return }
        // Review를 떠나면 그 결정에 대한 안내는 거둔다 (돌아오면 지금 상태가 말한다)
        if view != .review { review?.clearNotice() }
        if view == .review, review != nil, !(panelOpen && self.view == .review) { reviewPresentation += 1 }
        if view == .allWork, !(panelOpen && self.view == .allWork) { allWorkPresentation += 1 }
        self.view = view
        panelOpen = true
        menuOpen = false
        // 접었던 세션 패널이 다시 보이면(숨김 → 표시) 그 대화를 다시 읽는다. 세션 패널이 안 보이는 화면으로 가면 읽기 기록을 지운다
        loadPanelConversationIfNeeded()
        if view == .chats { onChatsOpened() }
        // All work로 들어오면 지금 들고 있는 응답이 처음 화면에 보인다: 아직 확정을 받지 않은 응답이면 그 표시 시점이다 (이미 받은 응답은 다시 받지 않는다)
        if view == .allWork { considerSummaryBaseline() }
    }

    /// All work: 레일의 All work · ⌘2. 고른 행 · 검색어 · 필터를 비우고 필터 카드를 닫는다 (디자인 "opens it with filters cleared")
    func openAllWork() {
        currentID = nil
        workFilter = WorkFilter()
        filtersOpen = false
        // 새 Issues 화면: ⌘2는 Projects 첫 화면이다 (쌓인 화면과 세션 패널을 비운다)
        if issues != nil {
            nav.reset()
            sessionPanelID = nil
        }
        openPanel(.allWork)
        if issues != nil { readSessionsOnEntry() }
    }

    /// Chats: 레일의 Chats · ⌘3. Assistant 창이 있으면 가장 앞 창을 앞으로 가져오고 없으면 연다 (패널은 그대로). 창이 없는 구성은 패널의 Chats로 마지막 대화로 돌아간다
    func openChats() {
        guard chatsEnabled else { return }
        if windowsEnabled {
            onChats()
            return
        }
        openPanel(.chats)
    }

    /// 새 대화: ⌘N. Assistant 창이 있으면 새 창을 연다. 창이 없는 구성은 패널의 대화 머리 `square-pen`과 같다: 손대지 않은 빈 대화가 있으면 그것을 다시 쓴다
    func newChat() {
        guard chatsEnabled else { return }
        if windowsEnabled {
            onNewWindow()
            return
        }
        openPanel(.chats)
        onNewChat()
    }

    /// 레일의 일: 그 일을 연다. 일 상세 · Review 화면은 다음 PR이라 지금은 All work에서 그 행을 표시한다.
    /// 남은 검색어 · 필터가 그 일을 가리면 검색어 · 필터를 비운다 (연 일이 목록에 보여야 한다)
    func open(itemID: UUID) {
        if issues != nil {
            openIssueFromOutside(itemID)
            return
        }
        currentID = itemID
        if let item = workItems.first(where: { $0.id == itemID }), !workFilter.matches(item) {
            workFilter = WorkFilter()
        }
        openPanel(.allWork)
    }

    // MARK: Issues (OA U2)

    /// 읽은 프로젝트(보관한 것 포함, 이름 · 아이콘 · 상태)
    var contextList: [WorkContext] { contexts.map { Array($0.contexts.values) } ?? [] }

    /// 멤버십을 읽었다 (읽기 전에는 Projects · 목록이 어떤 이슈도 어느 프로젝트에 두지 않는다: 아무것도 말하지 않는다)
    var membershipsKnown: Bool { contexts?.hasRead ?? false }

    /// 지금 열린 세션 패널의 세션
    var openSessionItem: AgentSessionItem? {
        guard let sessionPanelID else { return nil }
        return issues?.sessions.item(id: sessionPanelID)
    }

    /// Projects 목록의 행 (활성 프로젝트 이름순 → Ungrouped → Done today)
    var projectRows: [ProjectRowContent] {
        ProjectListRules.rows(items: workItems, contexts: contextList, sessions: issues?.sessions.items ?? [], today: DueDateFormat.today())
    }

    /// 이슈 목록 하나 (프로젝트 · Ungrouped · Done today). 없는 프로젝트 · 보관한 프로젝트면 nil
    func issueList(_ scope: IssueListScope) -> IssueListContent? {
        IssueListRules.content(scope: scope, items: workItems, contexts: contextList, sessions: issues?.sessions.items ?? [], today: DueDateFormat.today())
    }

    func issueItem(_ id: UUID) -> WorkItem? {
        workItems.first { $0.id == id }
    }

    /// 패널 머리 제목: 새 Issues 화면은 지금 연 화면이 정한다 (Projects · 프로젝트 이름 · "#139"). 번호를 아직 못 읽었으면 상세 제목은 비운다 (지어내지 않는다)
    var panelTitle: String {
        guard issues != nil, view == .allWork else { return view.title }
        switch nav.current {
        case .projects: return "Projects"
        case .list(let scope): return issueList(scope)?.title ?? ""
        case .detail(let id): return IssueNumberStore.label(issues?.numbers.number(for: id) ?? detailNumber(id)) ?? ""
        }
    }

    /// 상세를 읽어 온 번호 (목록용 배치 읽기가 아직 못 가져왔을 때)
    private func detailNumber(_ id: UUID) -> Int? {
        if case .ready(let content)? = issues?.details.screen(for: id) { content.number } else { nil }
    }

    /// 탭이 붙는 패널의 이슈들: 이슈 상세는 그 이슈, 프로젝트 · Ungrouped 목록은 그 목록의 이슈들. Projects · Done today에는 탭이 없다 (nil)
    var tabIssueIDs: Set<UUID>? {
        guard issues != nil, panelOpen, view == .allWork, let scope = nav.tabScope else { return nil }
        switch scope {
        case .detail(let id): return [id]
        case .list(let list): return issueList(list).map { Set($0.issueIDs) }
        case .projects: return nil
        }
    }

    /// 탭이 보이는가 (세션 패널은 탭이 있을 때만 열린다)
    var showsSessionTab: Bool { tabIssueIDs != nil }

    /// 탭 항목: 닫힌 세션은 없고 여섯과 More (현재 세션 · needs-you는 늘 남긴다)
    var tabPlan: AgentSessionTabPlan {
        guard let ids = tabIssueIDs, let issues else { return AgentSessionTabPlan(shown: [], hidden: []) }
        return AgentSessionRules.tabPlan(sessions: issues.sessions.sessions(of: ids), currentID: sessionPanelID)
    }

    /// 이슈 상세의 Sessions 목록: 만든 시각 순, 닫힌 세션은 맨 아래
    func sessions(of issue: UUID) -> [AgentSessionItem] {
        guard let issues else { return [] }
        return AgentSessionRules.listOrder(issues.sessions.sessions(of: [issue]))
    }

    /// 화면에 들어올 때마다 세션을 다시 읽는다 (U2-35): 5초 읽기가 멈춘 idle뿐인 상태에서도 다른 기기의 이름 · 상태 변화가 반영된다
    private func readSessionsOnEntry() {
        guard let issues else { return }
        Task { await issues.sessions.refresh() }
    }

    /// Projects에서 목록을 연다 (세션 패널은 닫는다)
    func openList(_ scope: IssueListScope) {
        guard issues != nil else { return }
        sessionPanelID = nil
        nav.open(scope)
        currentID = nil
        readSessionsOnEntry()
    }

    /// 목록에서 이슈 상세를 연다. 이미 그 상세가 열려 있으면 세션 패널을 둔다
    func openIssue(_ id: UUID) {
        guard issues != nil else { return }
        if nav.detailID != id { sessionPanelID = nil }
        nav.openDetail(id)
        currentID = id
        Task { await issues?.details.load(id) }
        readSessionsOnEntry()
    }

    /// 목록 밖(레일 · ⌘1 · 칩)에서 이슈를 연다: 뒤로는 그 이슈의 첫 프로젝트(이름순) 목록 또는 Ungrouped.
    /// 링 클릭이 이미 열린 같은 이슈면 세션 패널을 둔다 (다른 이슈면 닫는다)
    func openIssueFromOutside(_ id: UUID) {
        guard issues != nil else { return }
        let same = panelOpen && view == .allWork && nav.detailID == id
        if !same { sessionPanelID = nil }
        nav.openDetail(id, outside: issueItem(id).map(IssueNavigation.fallbackScope) ?? .ungrouped)
        currentID = id
        openPanel(.allWork)
        Task { await issues?.details.load(id) }
        readSessionsOnEntry()
    }

    /// 머리의 뒤로: 세션 패널도 닫는다
    func goBack() {
        guard issues != nil else { return }
        sessionPanelID = nil
        nav.back()
        currentID = nav.detailID
        readSessionsOnEntry()
    }

    /// SessionRow · 탭 항목: 탭이 붙은 패널 왼쪽에 세션 패널 (같은 세션이면 닫고, 다른 세션이면 바꾼다). 이슈 패널 없이 열리지 않는다
    func openSession(_ id: UUID) {
        guard issues != nil, showsSessionTab || (panelOpen && view == .allWork && nav.detailID != nil) else { return }
        sessionPanelID = sessionPanelID == id ? nil : id
        if sessionPanelID != nil { Task { await issues?.sessions.refresh() } }
        loadPanelConversationIfNeeded()
    }

    /// 세션 패널이 보이는 대화를 읽게 한다: 처음 열 때와 패널의 conversation id가 바뀔 때만 (같은 대화면 다시 부르지 않는다)
    private func loadPanelConversationIfNeeded() {
        guard sessionPanelShown, let conversation = openSessionItem?.conversationID else {
            // 세션 패널이 보이지 않거나 대화가 아직 없는 세션: 닫혀 있는 것과 같다 (다시 보이거나 대화가 생기면 그때 읽는다)
            loadedPanelConversation = nil
            return
        }
        guard conversation != loadedPanelConversation else { return }
        loadedPanelConversation = conversation
        onLoadSessionConversation(conversation)
    }

    /// 세션 패널 창이 실제로 보인다: 이슈 패널이 열려 있고 탭이 붙은 화면이고 세션 패널이 열려 있다 (`EdgeShell.followSessionPanel`과 같은 조건)
    var sessionPanelShown: Bool { panelOpen && showsSessionTab && openSessionItem != nil }

    func closeSessionPanel() {
        sessionPanelID = nil
    }

    /// New session `+`: 새 Assistant 창 + 범위 칩 + 대상 메뉴. 칩: 탭 = 그 패널의 이슈 또는 프로젝트, 레일 = 지금 패널에 열린 것 (없으면 칩 없음)
    func newSession(from source: NewSessionSource) {
        guard issues != nil else { return }
        let scope: AssistantOpenItem?
        switch source {
        case .rail:
            scope = openItem
        case .tab:
            scope = IssueOpenItemRules.openItem(
                screen: nav.current, session: nil, items: workItems, contexts: contextList, number: { [issues] in issues?.numbers.number(for: $0) }
            )
        }
        onNewSession(scope)
    }

    /// Esc의 Issues 차례 (열린 메뉴는 컨트롤러가 먼저 닫는다): 세션 패널 → 이슈 상세(목록으로). 그 밖은 접는다. 처리했으면 true
    func escapeIssues() -> Bool {
        if sessionPanelID != nil {
            sessionPanelID = nil
            return true
        }
        if nav.detailID != nil {
            // 머리 뒤로와 같은 길: 화면에 들어올 때마다 세션을 다시 읽는다 (재검토 반영 2)
            goBack()
            return true
        }
        return false
    }

    /// 읽은 것이 바뀐 뒤 열어 둔 화면을 맞춘다: 없어진 프로젝트의 목록은 Projects로, 없어진 이슈의 상세는 목록으로 (지우거나 병합된 이슈), 사라진 세션의 패널은 닫는다.
    /// 목록 · 멤버십 · 세션을 아직 읽지 못했으면 아무것도 닫지 않는다 (읽는 중에 화면을 치우지 않는다)
    func reconcileIssues() {
        guard let issues, case .loaded = work.load else { return }
        if membershipsKnown {
            let known = Set(workItems.map(\.id))
            let before = nav
            nav.reconcile(listExists: { issueList($0) != nil }, issueExists: { known.contains($0) })
            if nav != before { currentID = nav.detailID }
        }
        if issues.sessions.hasRead, let id = sessionPanelID, issues.sessions.item(id: id) == nil { sessionPanelID = nil }
        // 세션 패널은 탭이 붙은 이슈 패널 없이 열려 있지 않다 (Projects · Done today에는 탭이 없다)
        if sessionPanelID != nil, nav.tabScope == nil { sessionPanelID = nil }
    }

    /// 세션 · 번호가 바뀌었다: 레일의 링을 다시 정하고 열어 둔 화면을 맞춘다
    func sessionsChanged() {
        refreshSlots(at: clock())
        reconcileIssues()
        loadPanelConversationIfNeeded()
    }

    // MARK: Review (S4)

    /// Review 큐: 서버 순서 그대로 (`work.review`는 서버가 받았다고 답한 답을 이미 뺀 것이다, `NowStore.sections`)
    var reviewQueue: ReviewQueue { ReviewQueue(work.review) }

    /// 지금 Review 페이지가 보이는 결정. 보던 id가 큐에 없으면 nil
    var shownReview: ActionSummary? { reviewID.flatMap { reviewQueue.item($0) } }

    /// 본문에 무엇을 보일지: 받은 목록이 없으면 "결정이 없다"고 말하지 않는다
    var reviewScreen: ReviewScreen { ReviewScreen.of(load: work.load, hasDecision: shownReview != nil) }

    /// 레일에서 "지금 보는 일"로 표시할 id: Review 페이지가 보이면 그 결정, 아니면 All work에서 연 일
    var railCurrentID: UUID? { view == .review ? reviewID : currentID }

    /// 레일의 일을 누름. S4가 켜져 있고 Needs-you 링이면 그 Review 항목 (그 밖의 링은 그 일, 기존 동작 그대로)
    func openRailEntry(_ entry: RailEntry) {
        // 새 Issues 화면: needs-you가 세션의 질문이라 Review 큐에 그 이슈가 없으면 다른 이슈의 Review를 열지 않고 그 이슈의 상세를 연다
        if review != nil, entry.kind == .needsYou, issues == nil || reviewQueue.contains(entry.id) {
            openReview(itemID: entry.id)
        } else {
            open(itemID: entry.id)
        }
    }

    /// 그 Review 항목을 연다 (Needs-you 링 · 단계 점). 큐에 없으면(그사이 처리됨) 가장 새 항목. 열기는 어떤 답도 아니다
    func openReview(itemID: UUID) {
        guard review != nil else { return }
        reviewID = reviewQueue.contains(itemID) ? itemID : reviewQueue.newest?.id
        openPanel(.review)
    }

    /// ⌘1: 가장 새 Review 항목 (없으면 "No decisions waiting")
    func openNewestReview() {
        guard review != nil else { return }
        reviewID = reviewQueue.newest?.id
        openPanel(.review)
    }

    /// ← →: 큐에서 한 칸 (끝에서 돌지 않는다). 항목은 id로 옮긴다
    func stepReview(_ offset: Int) {
        guard review != nil, view == .review, let id = reviewID, let next = reviewQueue.neighbor(of: id, offset: offset) else { return }
        reviewID = next
    }

    /// 목록이 바뀐 뒤 보던 결정을 맞춘다: 보던 id가 그대로 있으면 순서가 바뀌어도 그 항목, 빠졌으면 그 뒤를 이은 항목(같은 index의 다른 항목이 아니라), 보던 것이 없으면 가장 새 항목
    private func reconcileReview(previous: [UUID]) {
        guard review != nil else { return }
        reviewID = reviewQueue.resolving(reviewID, previous: previous)
    }

    /// 사용자가 고른 답 하나 (클릭 · 1/2 키). `id`는 사용자가 본 항목의 id다: 지금 보이는 결정이 아니면(큐가 바뀌어 빠졌거나 다른 항목이 보임) 아무것도 하지 않는다.
    /// 오프라인이거나 Review가 보이지 않으면 보내지 않는다 (나중에 보내려고 모아 두지 않는다).
    /// **받는 이 동기 경계에서** 계정 token · 항목 · 이 방문(`reviewPresentation`)을 잡고, 예약된 작업이 실제로 보내기 직전에 다시 본다 (`ReviewDesk.send`):
    /// 그 사이 계정이 바뀌었거나(같은 UUID 재로그인 포함) 패널이 닫히고 화면이 옮겨지고 항목이 큐에서 빠지거나 더는 보이는 결정이 아니면 쓰기 0이다
    @discardableResult
    func answer(_ answer: ReviewAnswer, for id: UUID) -> Task<ReviewWriteResult, Never>? {
        guard let review, panelOpen, view == .review, reviewScreen.canAnswer, shownReview?.id == id,
              let ticket = review.begin(answer, for: id) else { return nil }
        let presentation = reviewPresentation
        return Task { [weak self] in
            let result = await review.send(ticket) {
                guard let self else { return false }
                return self.panelOpen && self.view == .review && self.reviewPresentation == presentation
                    && self.reviewScreen.canAnswer && self.shownReview?.id == id
            }
            // 서버가 받은 답이면 복귀 요약의 `Needs your answer`가 낡았을 수 있다: 서버의 지금 상태를 다시 읽는다 (읽기일 뿐, C3가 켜졌을 때만)
            if result == .applied { await self?.summary?.refresh() }
            return result
        }
    }

    // MARK: 복귀 요약 (C3)

    /// All work 위 카드가 그릴 것 (`C3Flag`가 꺼져 있으면 늘 nil). 줄을 누를 수 있나는 지금 목록에 그 작업이 있는가다: 열 곳이 없는 줄(지난 완료 · 취소)은 거짓 어포던스를 만들지 않는다
    var summaryContent: ReturnSummaryContent? {
        guard let summary else { return nil }
        let known = Set(workItems.map(\.id))
        return summary.content(canOpen: { known.contains($0) })
    }

    /// 복귀 요약의 줄을 누름 (열기는 어떤 결정도 해결도 아니다). 답할 결정이 **S4 Review가 답할 수 있는 확인 요청**이고 그 항목이 Review 큐에 있으면 Review로,
    /// 그 밖에는 지금 All work의 다른 줄처럼 그 작업을 연다 (일 상세는 아직 없다). Review 밖의 결정(approval · review_failed · run_input)은 S4b의 몫이다
    func openSummaryRow(_ actionID: UUID) {
        let decisions = summary?.summary?.items.first { $0.actionID == actionID }?.decisions ?? []
        if review != nil, decisions.contains(where: { $0.kind == .confirm }), reviewQueue.contains(actionID) {
            openReview(itemID: actionID)
        } else {
            open(itemID: actionID)
        }
    }

    /// Clear: 읽음 처리일 뿐이다 (해결 · 승인 · 완료 · 거절이 아니다). **받는 동기 경계에서** 계정 token · 커서와 이 **All work 방문**(`allWorkPresentation`)을 잡고,
    /// 예약된 작업이 보내기 직전에 같은 방문이 아직 이어지는지 다시 본다: 그 사이 패널이 닫혔다 다시 열렸거나 다른 화면에 갔다 돌아왔으면(새 방문) 옛 선택은 쓰기 0이다 (S4 `answer`와 같은 방식).
    /// 이미 서버로 나간 요청은 취소하지 않는다: 정직한 결과를 돌려준다. 보낼 수 없으면 nil (C3 꺼짐 · 패널이 닫힘/다른 화면 · 커서 없음 · 이미 보내는 중)
    @discardableResult
    func clearSummary() -> Task<ReturnSummaryClearResult, Never>? {
        guard let summary, panelOpen, view == .allWork, let ticket = summary.beginClear() else { return nil }
        let presentation = allWorkPresentation
        return Task { [weak self] in
            await summary.sendClear(ticket) {
                guard let self else { return false }
                return self.panelOpen && self.view == .allWork && self.allWorkPresentation == presentation
            }
        }
    }

    /// 첫 정상 표시 확정 (C): 복귀 요약 응답이 **정상 표시**됐을 때만 서버가 준 토큰으로 기준점을 확정한다 — 응답이 반영된 자리(`ReturnSummaryStore.onDisplayed`)와 All work로 들어오는 자리(`openPanel`)에서 부른다.
    /// 표시 시점의 **동기 경계에서** 계정 token · 서버 토큰 · 이 응답(`beginBaseline`)과 이 **All work 방문**(`allWorkPresentation`)을 잡고, 예약된 작업이 보내기 직전에 같은 방문이 아직 이어지는지 다시 본다:
    /// 그 사이 패널이 닫혔다 다시 열렸거나 Chats에 갔다 돌아왔으면(새 방문) 쓰기 0이다 (Clear · S4 `answer`와 같은 방식). 이미 서버로 나간 요청은 취소하지 않고 정직한 결과를 돌려준다.
    /// 읽음 표시일 뿐이다: 결정 · Action · run을 바꾸지 않는다. 보낼 수 없으면 nil (C3 꺼짐 · 패널이 닫힘/다른 화면 · 정상 표시가 아님 · 이 응답으로 이미 받음)
    @discardableResult
    func considerSummaryBaseline() -> Task<ReturnSummaryBaselineResult, Never>? {
        guard let summary, drawsSummary, panelOpen, view == .allWork, let ticket = summary.beginBaseline() else { return nil }
        let presentation = allWorkPresentation
        return Task { [weak self] in
            await summary.sendBaseline(ticket) {
                guard let self else { return false }
                return self.drawsSummary && self.panelOpen && self.view == .allWork && self.allWorkPresentation == presentation
            }
        }
    }

    /// 복귀 요약이 화면에 그려지는 구성인가: C3가 켜져 있고 All work(옛 홈)가 그 카드를 그린다. **새 Issues 화면이 켜지면 Projects에 요약이 없다**(계약 10장 2):
    /// 그릴 수 없는 요약의 "첫 정상 표시" 기준점을 서버에 확정하지 않는다 (읽음 표시는 사용자가 실제로 본 것만)
    var drawsSummary: Bool { summary != nil && issues == nil }

    /// 복귀 요약 Try again
    func retrySummary() {
        guard let summary else { return }
        Task { await summary.refresh() }
    }

    /// Esc: 안쪽 것(열린 필터 카드 · Chats의 대화 목록)을 먼저 닫고, 그다음 패널을 접는다 (디자인 Focus and keys)
    func escape() {
        if panelOpen, view == .allWork, issues != nil, escapeIssues() {
            return
        }
        if panelOpen, view == .allWork, filtersOpen {
            filtersOpen = false
        } else if panelOpen, view == .chats, onChatEscape() {
            return
        } else {
            dismiss()
        }
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

    // MARK: All work

    /// All work의 줄 (지금 시각의 기기 시간대로 Done today를 정한다). `timeEpoch`를 읽어, 시각 신호(`timeChanged`)가 오면 이 값을 읽은 화면이 다시 계산한다
    var workItems: [WorkItem] {
        _ = timeEpoch
        return work.items(now: clock(), calendar: calendar(), memberships: contexts?.index ?? .empty, numbers: issues?.numbers.numbers ?? [:])
    }

    /// 프로젝트(범위 멤버십)를 읽다 생긴 문제: 목록 위 Notice (할 일 목록의 문제가 먼저)
    var projectsProblem: WorkLoad.Problem? { contexts?.problem }

    /// 로컬 날짜 · 시간대 · 시스템 시계가 바뀌었거나 Mac이 깨어났다: 열린 채 기다리던 패널이 "오늘"을 다시 계산한다.
    /// 목록을 새로 읽지는 않는다: 지난 Done today는 허용된 새로 읽기(로그인 · 패널 열기 · Try again · 동기화 끝) 전까지 빠진 채로 둔다
    func timeChanged() {
        timeEpoch &+= 1
    }

    func setFilter(_ filter: WorkFilter) {
        workFilter = filter
    }

    func setFiltersOpen(_ open: Bool) {
        filtersOpen = open
    }

    /// 고정 (셋까지, 지금 목록의 일만). 고정한 일은 그 묶음 맨 앞
    func pin(_ id: UUID) {
        guard let account else { return }
        var pins = self.pins
        guard pins.pin(id, known: Set(workItems.map(\.id))) else { return }
        self.pins = pins
        pinStore.save(pins, account: account)
    }

    func unpin(_ id: UUID) {
        guard let account, pins.isPinned(id) else { return }
        pins.unpin(id)
        pinStore.save(pins, account: account)
    }

    /// 로그인 계정이 바뀜 (로그아웃 · 다른 계정 · 같은 계정의 첫 로그인): 전 계정의 검색어 · 필터 · 열린 필터 · 고른 행을 비우고 그 계정의 고정을 읽는다.
    /// 토큰 갱신처럼 같은 계정이면 그대로 둔다
    func accountChanged(_ account: UUID?) {
        guard account != self.account else { return }
        self.account = account
        workFilter = WorkFilter()
        filtersOpen = false
        currentID = nil
        hoveredID = nil
        reviewID = nil
        nav.reset()
        sessionPanelID = nil
        pins = account.map { pinStore.load(account: $0) } ?? WorkPins()
    }

    // MARK: 데이터

    /// 목록 · run이 바뀔 때마다. 레일의 칸은 남아 있는 일의 순서를 지킨다 (`RailOrdering`)
    func update(_ work: EdgeWorkSnapshot) {
        let now = clock()
        let previousReview = self.work.review.map(\.id)
        let wasOnRail = Set(slots.filter { $0.kind != .done }.map(\.id))
        let doneIDs = Set(work.doneToday.map(\.id))
        let liveIDs = Set(work.review.map(\.id)).union(work.working)
        // 레일에 있던 일이 지금 끝남 → 3초 동안 Done
        for id in wasOnRail where doneIDs.contains(id) && !liveIDs.contains(id) && recentlyDone[id] == nil {
            recentlyDone[id] = now
        }
        self.work = work
        reconcileReview(previous: previousReview)
        refreshSlots(at: now)
        reconcileIssues()
    }

    /// Done 3초가 지난 일을 뺀다
    func expireDone() {
        refreshSlots(at: clock())
    }

    private func refreshSlots(at now: Date) {
        recentlyDone = recentlyDone.filter { now.timeIntervalSince($0.value) < TFMotion.doneHold }
        let entries = Self.entries(work, recentlyDone: recentlyDone, sessions: issues?.sessions.items)
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

    /// 지금 레일에 오를 수 있는 일: 확인 요청(needs you) · run이 도는 일(running · stop requested) · 막 끝난 일(done).
    /// `sessions`가 있으면(새 Issues 화면) 링 하나 = 이슈 하나다: 그 이슈의 v1 링과 닫히지 않은 세션들의 링 중 먼저인 것 (needs-you → unreachable → stopping → running → done → waiting).
    /// 세션만 있는 이슈(v1 run 없이 세션이 돈다)도 오른다. idle 세션은 링이 아니다
    static func entries(_ work: EdgeWorkSnapshot, recentlyDone: [UUID: Date], sessions: [AgentSessionItem]? = nil) -> [RailEntry] {
        guard let sessions else {
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
        var entries: [RailEntry] = []
        var seen = Set<UUID>()
        func add(_ action: ActionSummary, v1: AgentSessionRing?, state: TaskStatusMark.State) {
            guard seen.insert(action.id).inserted else { return }
            let mine = AgentSessionRules.sessions(of: [action.id], in: sessions)
            guard let ring = AgentSessionRules.issueRing(v1: v1, sessions: mine) else { return }
            entries.append(RailEntry(id: action.id, title: action.title, kind: ActivityRing.Kind(ring), state: state, activity: ring.railActivity))
        }
        for action in work.review { add(action, v1: .needsYou, state: TaskStatusMark.State(.review)) }
        for action in work.open {
            let v1: AgentSessionRing? = work.working.contains(action.id) ? (work.stopping.contains(action.id) ? .stopping : .running) : nil
            add(action, v1: v1, state: TaskStatusMark.State(TaskGroup.open(action)))
        }
        for action in work.doneToday where recentlyDone[action.id] != nil { add(action, v1: .done, state: .done) }
        return entries
    }
}

extension AgentSessionRing {
    /// 레일 항목의 활동 글: 링의 말과 다른 것만 (Stop 요청 · 연결 끊김은 설명이 붙는다)
    var railActivity: String? {
        switch self {
        case .stopping: WorkActivity.stopRequested
        case .unreachable: AgentSessionRules.connectionLost
        default: nil
        }
    }
}
#endif
