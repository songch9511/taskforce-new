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
/// Release 빌드는 `EdgeSurfaces.shippedForThisBuild`(기본 `release`, 내부 배포 빌드는 `internalBuild`)를 따른다: Edge 셸은 켜진다 (⌥ Space는 Edge 패널을 연다). DEBUG는 위 인자 그대로.
enum EdgeShellFlag {
    static let key = "TF_EDGE_SHELL"

    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).shell
        #else
        return EdgeSurfaces.shippedForThisBuild.shell
        #endif
    }
}

/// 0.2.0 S3b(범위 멤버십 · ProjectLink)를 켜는 플래그. **기본은 꺼짐** → All work는 S3 그대로다:
/// 실제 앱 생성 경로(`AppRuntime.makeChatRuntime`)가 범위 멤버십 게이트웨이 · 저장소를 아예 만들지 않아 RLS 멤버십 읽기 · 멤버십 쓰기 · ProjectLink 연결이 없고,
/// 모든 할 일은 Ungrouped이며 검색 · 필터는 기존 그대로다. B3 Chats · Remembered와 Edge 셸은 그대로 유지된다.
/// (`TF_EDGE_SHELL`을 끄면 구 런처로 돌아가는 것이지 S3로 돌아가는 것이 아니다: 두 플래그는 다른 축이다. 서버 `MEMORY_ENABLED`도 POST만 막는 또 다른 축이다.)
/// - 앱: launch argument `-TF_S3B YES`만 (인자 영역. 저장된 defaults로는 켜지지 않는다). `TF_EDGE_SHELL`이 켜진 격리 Debug 실행에서만 뜻이 있다
/// - 테스트: 전용 UserDefaults suite를 넘긴다
/// 기본 Release 빌드는 늘 꺼짐이다 (`EdgeSurfaces.release.projects`, Chats 런타임이 없어 범위 멤버십도 없다). 내부 배포 빌드(`internalBuild`)만 켜진다.
enum S3bFlag {
    static let key = "TF_S3B"

    static func isEnabled(_ defaults: UserDefaults? = nil) -> Bool {
        #if DEBUG
        return EdgeSurfaces.debug(defaults).projects
        #else
        return EdgeSurfaces.shippedForThisBuild.projects
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
        return EdgeSurfaces.shippedForThisBuild.review
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
        return EdgeSurfaces.shippedForThisBuild.summary
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
        /// Sessions (OA PR-D2, 계약 23장): Taskforce 세션과 이 Mac의 Claude 세션을 모두 한 곳에서 본다 (옛 On this Mac은 이 패널의 한 절이다). 새 Issues 화면(캡슐 레일)의 셸에서만 열린다 (`sessionsVisible`)
        case sessions
        /// Claude 데스크톱 세션 보기 하나 (읽기 전용, OA PR-D2 계약 21.2 DR-S1d): **레일의 데스크톱 링을 눌러** 연다 — 이슈 패널 없이 한 패널만 레일 옆에 선다.
        /// Sessions의 줄을 눌러 열면 Sessions 패널은 그대로 두고 그 왼쪽에 선다 (`.sessions` + `desktopPanelID`). 이 화면의 본문은 메인 패널 창이 아니라 Claude 세션 패널 창이 그린다
        case claudeApp

        /// 패널 머리 제목. All work 화면의 머리는 "Your work"다 (디자인 WorkPage · WorkList 견본). 레일 칸 이름은 그대로 All work.
        /// Review의 머리는 그 결정의 항목 이름이다 (디자인 PanelHeader "Launch timing"): 이 값은 항목이 없을 때(빈 · 읽는 중 · 오프라인)의 머리다
        var title: String {
            switch self {
            case .allWork: "Your work"
            case .chats: "Chats"
            case .review: "Review"
            case .sessions: SessionsPanelCopy.title
            // 머리는 Claude 세션 패널이 세션 이름으로 그린다 (이 값은 메인 패널 머리가 아니다)
            case .claudeApp: AgentMarkKind.claudeCode.accessibilityName
            }
        }
    }

    /// 레일의 고정 칸
    enum Control: String, CaseIterable {
        case allWork, chats, sessions, more

        /// 노치 레일(옛 구성)의 셋째 칸. `sessions`는 여기 없다: 첫 캡슐(세션 링 · `+`)의 맨 위 버튼이다 (`EdgeShellModel.sessionsVisible`). `allCases`는 빠짐없는 목록이다
        static let defaultControls: [Control] = [.allWork, .chats, .more]
        /// 캡슐 레일(새 Issues 화면)의 셋째 캡슐 칸 (계약 24장, 사용자 결정 2026-10-22): **Chats 칸이 없다** — 새 세션은 `+`가 새 대화 창으로 열고, 지난 대화는 대화 창의 기록 단추와 Sessions 패널에서 찾는다
        static let capsuleControls: [Control] = [.allWork, .more]

        /// 이 칸을 누르는 키 명령 (없으면 키가 없다)
        var keyCommand: EdgeKeyCommand? {
            switch self {
            case .allWork: .allWork
            case .chats: .chats
            case .sessions: .sessions
            case .more: nil
            }
        }

        var label: String {
            switch self {
            case .allWork: "All work"
            case .chats: "Chats"
            case .sessions: SessionsPanelCopy.title
            case .more: "More"
            }
        }

        /// 칸의 단축키 (More는 없음): 툴팁(DZ 승인 "Sessions ⌘4")과 Settings › Shortcuts(`SettingsPanelKeys`가 `allCases`에서 읽는다)가 같은 값을 쓴다
        var shortcut: String? {
            switch self {
            case .allWork: "⌘2"
            case .chats: "⌘3"
            case .sessions: SessionsPanelCopy.shortcut
            case .more: nil
            }
        }
    }

    /// 이 셸의 셋째 캡슐 칸. 캡슐 레일(새 Issues 화면)은 Projects · More 둘이다 (Chats 칸 없음, 계약 24장). 노치 레일(옛 구성)은 Chats가 꺼져 있으면 Chats 칸이 없다.
    /// Sessions는 첫 캡슐의 버튼이라 여기 없다 (옛 On this Mac 칸은 Sessions로 합쳐 없앴다, OA PR-D2)
    var controls: [Control] {
        if issues != nil { return Control.capsuleControls }
        return chatsEnabled ? Control.defaultControls : Control.defaultControls.filter { $0 != .chats }
    }

    /// 고정 칸의 이름. 새 Issues 화면이 켜진 셸의 첫 칸은 "Projects"다 (툴팁 "Projects ⌘2", OA U2b 사용자 결정: U2의 "Issues"를 바꿨다): 꺼져 있으면 "All work"
    func label(for control: Control) -> String {
        control == .allWork && issues != nil ? Self.projectsLabel : control.label
    }

    static let projectsLabel = "Projects"

    /// 고정 칸의 아이콘 (레일이 그린다). 새 Issues 화면이 켜진 셸의 첫 칸은 lucide `folder`, 꺼져 있으면 `list-todo`
    func railIcon(for control: Control) -> TFIcon {
        switch control {
        case .allWork: issues != nil ? .project : .allWork
        case .chats: .talk
        case .sessions: .sessions
        case .more: .more
        }
    }

    static let newSessionLabel = "New session"

    /// 이 셸이 듣는 키 명령인가: Chats가 꺼져 있으면 ⌘3 · ⌘N은 연결이 없어 지나간다 (먹지 않는다). ⌘3(Chats)은 Chats 칸이 있는 노치 레일만 듣는다 (캡슐 레일은 Chats 칸 · 키가 없다, 계약 24장 —
    /// 새 대화는 ⌘N · `+`). ⌘4(Sessions)는 Sessions 버튼이 있는 셸만 듣는다
    func listens(to command: EdgeKeyCommand) -> Bool {
        switch command {
        case .chats: chatsEnabled && issues == nil
        case .newChat: chatsEnabled
        case .sessions: sessionsVisible
        case .escape, .review, .allWork: true
        }
    }

    private(set) var slots: [RailEntry] = []
    /// 노치에 120ms 머물러 펼친 레일 (패널이 열려 있으면 `isExpanded`가 따로 참)
    private(set) var railHovered = false {
        // 레일이 펼쳐질 때 한 번 훑는다 (데스크톱 링의 제목 · 툴팁을 위해, 패널이 열려 있으면 이미 훑고 있다)
        didSet { if railHovered, !oldValue, externalSessionsVisible { externalSessions?.railExpanded() } }
    }
    private(set) var panelOpen = false {
        // 패널을 접으면 세션 패널의 대화 읽기 기록을 지운다: 접어 둔 사이 온라인 복귀 · 목록 새로 읽기가 그 대화의 캐시를 비웠을 수 있어
        // 복원(⌥Space)하면 같은 conversation id여도 다시 읽는다 (재검토 반영 1)
        didSet {
            if !panelOpen { loadedPanelConversation = nil }
            externalSessionsPanelChanged()
            desktopPanelChanged()
        }
    }
    private(set) var view: View = .allWork {
        didSet {
            externalSessionsPanelChanged()
            desktopPanelChanged()
        }
    }
    /// 레일에서 연 일 (패널 목록에서 그 행을 표시)
    private(set) var currentID: UUID?
    /// 포인터 아래의 레일 칸. 패널이 닫혀 있으면 툴팁, 열려 있으면 패널의 그 행을 표시한다
    private(set) var hoveredID: UUID?
    private(set) var hoveredControl: Control?
    private(set) var menuOpen = false
    /// More 카드가 닫힐 때마다 오른다: 레일이 접근성 포커스를 ⋯로 돌려준다 (OA U3 16.1)
    private(set) var moreFocusSerial = 0
    /// ⋯가 접근성 포커스를 실제로 받은 마지막 번호 (`moreFocusSerial`과 같으면 돌려준 것이다). ⋯ 칸 뷰 자신이 포커스를 주었을 때만 알린다
    private(set) var moreFocusLandedSerial = 0
    /// More 카드가 닫혀 ⋯가 접근성 포커스를 받으러 가는 번호: ⋯가 `moreFocusLanded`로 알리면 비운다.
    /// 받기 전에는 레일이 접히지 않는다 (접히면 ⋯ 칸이 사라져 포커스를 돌려줄 곳이 없다)
    private(set) var moreFocusPending: Int?
    @ObservationIgnored private var moreFocusHold: EdgeTimer?
    /// 끝내 ⋯가 포커스를 받지 못해도(칸이 안 그려짐 등) 레일이 영영 펼쳐 있지 않게 하는 상한
    static let moreFocusHoldLimit: TimeInterval = 2
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
    /// 새 Issues 화면(OA U2): 세션 · 번호 · 상세를 읽는 곳. **없으면 게이트가 꺼진 것이다** — Projects · 이슈 목록 · 상세 · 세션 패널이 없고 All work는 지금 그대로다 (`EdgeSurfaces.issueScreens`)
    let issues: IssueRuntime?
    /// 이 Mac의 Claude Code 세션 목록 (OA 외부 세션 PR1). **없으면 게이트가 꺼진 것이다**(새 Issues 화면 ∧ `BridgeFlag` ∧ 로그인): Sessions 패널의 On this Mac 절도 훑기도 서버 보고도 없다
    let externalSessions: ExternalSessionsStore?
    /// Claude 데스크톱 앱에 열린 세션의 살아 있는 상태 (OA PR-D2, 계약 21 · 23장): 레일의 데스크톱 링 · Sessions 줄의 링 · 세션 보기의 상태 말. **목록(`externalSessions`)과 같은 게이트**다: 없으면 데스크톱 링도 세션 보기도 없다
    let desktop: ClaudeAppSessionsModel?
    /// 아직 안 연 끝남의 저장 (계약 23장): 있고 새 Issues 화면이 켜진 셸은 끝난 링(초록)이 **열어 볼 때까지** 레일에 남는다 (타이머 없음, 이 Mac에 저장 → 다시 켠 뒤에도). 없으면 지금처럼 3초다 (노치 레일 · 시험)
    @ObservationIgnored let railDone: (any RailDoneStore)?
    /// 표시만 남은 끝난 이슈를 id로 읽는다 (기존 RLS 읽기, `IssueRuntime.finished`). 시험은 가짜로 바꾼다. 새 Issues 화면이 없는 셸은 읽지 않는다
    @ObservationIgnored var lookupFinishedIssue: @MainActor (UUID) async -> FinishedIssueResult = { _ in .unknown }
    /// 데스크톱 세션 보기를 연 날의 지표 (하루 한 번, 종류만). 없으면 보내지 않는다
    @ObservationIgnored private let claudeAppOpened: ClaudeAppOpenedMetric?
    /// 데스크톱 세션 하나의 대화 읽기를 만든다 (세션 id, 등록 파일의 작업 폴더): 실제 앱은 `~/.claude`의 기록을 읽는 `ClaudeAppTranscriptReader`, 시험은 가짜
    @ObservationIgnored var makeConversation: @MainActor (String, String?) -> ClaudeAppConversation = EdgeShellModel.liveConversation
    /// 한 세션의 백그라운드 일 하나의 출력 꼬리 읽기를 만든다 (세션 id, 작업 폴더, 그 일): 실제 앱은 이 Mac의 기록 · 임시 폴더를 좁게 읽는 `BackgroundTaskTail`, 시험 · 견본은 가짜.
    /// Claude 세션 보기와 Taskforce 세션 패널이 같이 쓴다 (Taskforce는 이 Mac의 기록이 묶은 Claude 세션 id로 부른다)
    @ObservationIgnored var makeBackgroundTail: @MainActor (String, String?, BackgroundTask) -> BackgroundTaskTailModel = EdgeShellModel.liveBackgroundTail
    /// Esc가 먼저 닫을 옆줄이 있나 (꼬리 → 목록 → 접힘): Claude 세션 패널 컨트롤러가 채운다. 닫았으면 true
    @ObservationIgnored var onEscapeDesktopPane: () -> Bool = { false }
    /// 세션 보기가 이 Mac에 두는 것(열어 본 시각의 저장본 · 일 목록 판)을 계정과 함께 보내는 곳 (보안 P3-1): 로그인이 바뀔 때 주인을 확정하고, 알던 계정이 떠나면 판을 비운다. 앱이 채운다
    @ObservationIgnored var backgroundSessions: BackgroundTaskAccount?
    /// 지금 보이는 Claude 데스크톱 세션 (세션 id): 레일 링 · Sessions 줄을 눌러 연다. 메인 패널이 Sessions면 그 왼쪽 패널로, `.claudeApp` 화면이면 레일 옆 한 패널로 선다
    private(set) var desktopPanelID: String? {
        didSet { desktopPanelChanged() }
    }
    /// 그 세션의 대화 (패널이 보이는 동안 라이브 꼬리를 읽는다). 세션 보기가 없으면 nil
    private(set) var desktopConversation: ClaudeAppConversation?
    @ObservationIgnored private var desktopConversationShown = false
    @ObservationIgnored private var viewedDesktopID: String?
    /// 데스크톱 세션과 대화하는 흐름 (OA PR-D3, 계약 25장): 입력창 · 보내기 전 확인 · 전달 줄 · 저장. **`ClaudeAppRelayGate`가 켜진 빌드(Debug · 내부 배포)에서만 있다** — 없으면(Release) 세션 보기는 읽기 전용 그대로다.
    /// 세션 보기와 같은 게이트(`desktop`)가 켜져 있을 때만 쓴다
    let desktopChat: ClaudeAppChatService?
    /// 지금 입력창을 보이고 있는 세션 (패널이 보이는 동안만): 바뀌면 이전 세션의 입력창을 접는다
    @ObservationIgnored private var visibleChatID: String?

    /// 이 실행의 Taskforce 게이트 (`EdgeSurfaces.taskforceConversation`: Debug에서 다섯 인자가 모두 있을 때만, Release 빌드는 늘 false). 셸이 만들어지는 자리에서 한 번 정한다 (OA U3 검토 1)
    let taskforceGate: Bool
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
    /// New session `+`가 눌렸다: 창 관리자가 새 Assistant 창을 열고 범위 칩을 달아 대상 메뉴를 연다 (칩은 눌린 곳의 범위)
    @ObservationIgnored var onNewSession: (AssistantOpenItem?) -> Void = { _ in }
    /// Ask 알약: 앞 Assistant 창에 그 항목의 칩을 더한다 (창이 없으면 새 창). 컨트롤러가 창 관리자에 잇는다
    @ObservationIgnored var onAsk: (AssistantOpenItem) -> Void = { _ in }
    /// 인용의 원문 링크를 연다 (시험은 가짜로 바꾼다)
    @ObservationIgnored var onOpenURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// 세션 머리 알약(Open in Terminal · Resume here)의 동작 (OA D4a-15 · 16). **없으면 알약을 그리지 않는다**: 세션 패널 컨트롤러가 실제 연결이 세션 route를 알 때 `AgentSessionPillFlow`에 잇는다
    @ObservationIgnored var onSessionPill: ((AgentSessionPill, AgentSessionItem) -> Void)?
    /// 새로 읽은 세션들 (OA D4a-16): 확인 카드가 낡았는지 본다 — 세션 패널 컨트롤러가 채운다
    @ObservationIgnored var onSessionItemsChanged: ([AgentSessionItem]) -> Void = { _ in }
    /// Esc가 먼저 닫을 것이 있나: 열린 Resume 확인 카드 · 후보 고르기 메뉴 (OA D4a). 닫았으면 true — 세션 패널 컨트롤러가 채운다
    @ObservationIgnored var onEscapeSessionOverlay: () -> Bool = { false }
    /// 이 Mac의 bridge id (OA D4a-03): 세션 알약은 그 세션 연결의 `bridge_id`가 이것과 같을 때만 보인다. 모르면 nil (bridge가 꺼졌거나 아직 등록 전: 알약이 없다)
    var thisMacBridgeID: UUID?
    /// 이 Mac의 bridge id를 읽는다 (`BridgeHost`의 런타임, 원장 meta). 세션 패널이 열릴 때 부른다
    @ObservationIgnored var localBridgeIDProvider: @MainActor () async -> UUID? = {
        guard let runtime = BridgeHost.shared?.activeRuntime else { return nil }
        return await runtime.localBridgeID()
    }

    func refreshThisMac() async {
        let id = await localBridgeIDProvider()
        if thisMacBridgeID != id {
            thisMacBridgeID = id
            // 같은 값을 질문 저장소도 쓴다: 이 Mac의 세션이면 비밀값 카드가 입력 칸을 가진다
            questions?.thisMacBridgeID = id
        }
    }

    /// 에이전트의 열린 질문 (OA D4b-m-1). 없으면 질문 카드가 없다 — 컨트롤러가 `ChatRuntime.questions`를 잇는다
    @ObservationIgnored var questions: AgentQuestionStore?
    /// 질문 카드에 키 포커스를 줘야 할 때 (링 클릭 · 알림 누름: 사용자의 동작으로 그 세션이 열렸다) 컨트롤러가 그 창을 키 창으로 만든다. 창 · 패널이 스스로 키를 가져가지는 않는다
    @ObservationIgnored var onFocusQuestion: (UUID) -> Void = { _ in }

    /// 그 세션의 질문으로 간다 (needs-you 링 클릭, 알림 누름: D4bm-57 · 63): 그 이슈 상세 + 그 세션 패널을 열고 카드로 포커스를 옮긴다. 이미 열려 있으면 닫지 않는다
    func openQuestion(session: UUID) {
        guard issues != nil, let item = issues?.sessions.item(id: session) else { return }
        if let issue = item.currentIssueID ?? item.issueIDs.first { open(itemID: issue) }
        if sessionPanelID != session { openSession(session) }
        questions?.requestFocus(session: session)
        onFocusQuestion(session)
    }
    /// 포인터가 Review 타일 위에 있다 (툴팁 · 호버 덧칠)
    private(set) var hoveredTile = false
    /// 포인터가 New session `+` 위에 있다 (OA U2, 툴팁 · 호버 덧칠)
    private(set) var hoveredPlus = false
    /// Review 페이지가 보이는 결정의 stable action id. 몇 번째인지(index)가 아니라 id로 가리킨다: 큐가 바뀌어도 키 · 클릭은 이 id의 항목에만 간다
    private(set) var reviewID: UUID?
    /// Taskforce 대화가 보이는 요청의 안정 id (`kind:열쇠`, OA U3). 몇 번째인지가 아니라 id로 가리킨다. 게이트가 꺼지면 늘 nil
    private(set) var taskforceShownID: String?
    /// 마지막으로 맞춘 요청 id 순서: 보던 요청이 빠지면 그 뒤를 이은 요청을 보인다
    @ObservationIgnored private var taskforcePreviousIDs: [String] = []
    /// 포인터가 Taskforce bell 위에 있다 (툴팁 · 호버 덧칠, OA U3)
    private(set) var hoveredBell = false
    /// 세션 저장소에서 task 상태가 바뀌었나 보는 지문 (바뀔 때만 v2 Review를 다시 읽는다, U3-20)
    @ObservationIgnored private var taskforceSessionSignature: [UUID: String] = [:]
    /// 마지막으로 읽은 v1 확인 요청 id들 (바뀔 때만 v2 Review를 다시 읽는다, U3-20)
    @ObservationIgnored private var taskforceConfirmationIDs: Set<UUID> = []
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
        windowsEnabled: Bool = false, issues: IssueRuntime? = nil, taskforceGate: Bool = EdgeSurfaces.taskforceConversationForThisRun,
        externalSessions: ExternalSessionsStore? = nil, desktopSessions: ClaudeAppSessionsModel? = nil, railDone: (any RailDoneStore)? = nil,
        claudeAppOpened: ClaudeAppOpenedMetric? = nil, desktopChat: ClaudeAppChatService? = nil
    ) {
        self.issues = issues
        self.externalSessions = issues == nil ? nil : externalSessions
        self.desktop = issues == nil || externalSessions == nil ? nil : desktopSessions
        self.desktopChat = issues == nil || externalSessions == nil || desktopSessions == nil ? nil : desktopChat
        self.railDone = issues == nil ? nil : railDone
        if let finished = issues?.finished { lookupFinishedIssue = { await finished.read($0) } }
        self.claudeAppOpened = issues == nil || externalSessions == nil ? nil : claudeAppOpened
        if issues != nil, let railDone {
            // 끝난 링은 열어 볼 때까지 남는다: 세션 저장소도 같은 저장소로 올리고, 저장해 둔 이슈의 끝남을 되살린다
            issues?.sessions.useDoneStore(railDone)
            recentlyDone = railDone.load().issues
        }
        self.taskforceGate = taskforceGate
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
        // Taskforce 충돌 해소의 2초 보류는 셸의 주입 시계로 만든다 (시험이 손으로 돌린다, OA U3-27)
        issues?.taskforce.schedule = { delay, work in
            let timer = schedule(delay, work)
            return { timer.cancel() }
        }
    }

    // MARK: 레일 모양

    /// 펼친 레일: 노치 호버 · 열린 패널(패널 옆 레일은 늘 펼친다) · ⋯가 포커스를 받으러 가는 중(`moreFocusPending`)
    var isExpanded: Bool { railHovered || panelOpen || moreFocusPending != nil }
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
        // DS EdgeRail 미리보기: "Taskforce · Needs your answer · ⌘1" (이름 · 접근성 이름은 단축키 없이 두 말 그대로)
        if hoveredBell, let bell = taskforceBell {
            let parts = Self.splitTooltip(bell.tooltip)
            return (parts.title, parts.detail + " · " + Self.taskforceShortcut)
        }
        if hoveredPlus { return (Self.newSessionLabel, "") }
        // "제목 · 상태 · 활동" (Claude 데스크톱 세션은 Taskforce 업무 상태가 없어 "제목 · 활동")
        if let hoveredID, let entry = slots.first(where: { $0.id == hoveredID }) {
            return (entry.title, "· " + (entry.state.map { "\($0.label) · " } ?? "") + entry.activity)
        }
        if let hoveredControl, let shortcut = hoveredControl.shortcut {
            return (label(for: hoveredControl), shortcut)
        }
        return nil
    }

    /// "앞 낱말 · 나머지" → (앞 낱말은 굵게, 나머지는 보조색)
    static func splitTooltip(_ text: String) -> (title: String, detail: String) {
        guard let separator = text.range(of: " · ") else { return (text, "") }
        return (String(text[..<separator.lowerBound]), "· " + text[separator.upperBound...])
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
            hoveredBell = false
            scheduleLeave()
        }
    }

    /// 포인터가 나간 뒤 400ms에 접는다. 메뉴(More 카드)가 열려 있거나 ⋯가 포커스를 받으러 가는 중이면 접지 않는다: 그 일이 끝날 때 다시 부른다
    private func scheduleLeave() {
        guard railHovered, leaveTimer == nil else { return }
        leaveTimer = schedule(TFMotion.railLeaveDelay) { [weak self] in
            guard let self else { return }
            self.leaveTimer = nil
            if !self.pointerInside, !self.menuOpen, self.moreFocusPending == nil { self.railHovered = false }
        }
    }

    func hover(item id: UUID?) {
        hoveredID = id
        if id != nil {
            hoveredControl = nil
            hoveredTile = false
            hoveredPlus = false
            hoveredBell = false
        }
    }

    func hover(control: Control?) {
        hoveredControl = control
        if control != nil {
            hoveredID = nil
            hoveredTile = false
            hoveredPlus = false
            hoveredBell = false
        }
    }

    /// 포인터가 Review 타일 위에 있다
    func hover(tile: Bool) {
        hoveredTile = tile
        if tile {
            hoveredID = nil
            hoveredControl = nil
            hoveredPlus = false
            hoveredBell = false
        }
    }

    /// 포인터가 New session `+` 위에 있다 (OA U2)
    func hover(plus: Bool) {
        hoveredPlus = plus
        if plus {
            hoveredID = nil
            hoveredControl = nil
            hoveredTile = false
            hoveredBell = false
        }
    }

    /// 포인터가 Taskforce bell 위에 있다 (OA U3)
    func hover(bell: Bool) {
        hoveredBell = bell
        if bell {
            hoveredID = nil
            hoveredControl = nil
            hoveredTile = false
            hoveredPlus = false
        }
    }

    // MARK: Review 타일 (OA U1)

    /// 레일 맨 위 타일이 보일 것: needs-you(지금 Review 큐)만, 없으면 없음 (바뀐 것만 있을 때도 없다, OA U2b). 타일은 Review(S4)와 복귀 요약(C3)이 둘 다 켜졌을 때만 있다
    var reviewTileContent: ReviewTileContent? {
        // 캡슐 레일(새 Issues 화면)에는 타일이 없다: Taskforce bell이 그 자리다. 타일은 Release 경로(노치 레일)에만 남는다 (OA U3-01)
        guard !issueScreensEnabled else { return nil }
        return ReviewTileRules.content(reviewCount: reviewQueue.count, reviewEnabled: review != nil, summaryEnabled: summary != nil)
    }

    /// 툴팁: "Review · Needs your answer" (앞 낱말은 굵게, 나머지는 보조색)
    var tileTooltip: (title: String, detail: String)? {
        guard let content = reviewTileContent else { return nil }
        let text = ReviewTileRules.tooltip(content)
        guard let separator = text.range(of: " · ") else { return (text, "") }
        return (String(text[..<separator.lowerBound]), "· " + text[separator.upperBound...])
    }

    var tileAccessibilityName: String? {
        reviewTileContent.map { ReviewTileRules.accessibilityName($0) }
    }

    /// Open 링: 타일이 데려가는 Review 화면이 보이는 동안. 열기는 어떤 답도 아니다
    var tileOpen: Bool {
        panelOpen && reviewTileContent != nil && view == .review
    }

    /// 타일을 누름: 가장 새 Review 항목. 타일이 없으면 아무 일도 없다 (목록 화면 `ReviewList`는 D4b-m)
    func openReviewTile() {
        guard reviewTileContent != nil else { return }
        openNewestReview()
    }

    /// 패널에서 지금 열린 항목 (Assistant 창의 auto 칩이 따라간다): All work에서 연 일 · Review가 보이는 결정. 패널이 닫혀 있으면 없다.
    /// 새 Issues 화면이 켜져 있으면 가장 안쪽에 열린 것이다 (세션 패널 → 그 세션, 이슈 상세 → 그 이슈(번호 앞), 프로젝트 목록 → 그 프로젝트, 그 밖은 없음)
    var openItem: AssistantOpenItem? {
        guard panelOpen else { return nil }
        switch view {
        case .review:
            // Taskforce 대화에서는 확인 요청의 이슈만 열린 항목이다 (결과 · 충돌 카드는 이슈 하나가 아니다)
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
        case .chats, .sessions, .claudeApp:
            return nil
        }
    }

    // MARK: 패널

    /// ⌥ Space: 열려 있으면 접고, 아니면 **가장 새 Review 항목** (Taskforce 대화가 켜진 구성은 가장 오래 기다린 요청), 기다리는 결정이 없으면 마지막에 본 화면을 연다 (DS Behaviors › Review: "⌥ Space opens the newest Review item, or the last view when nothing waits").
    /// 열기는 어떤 답도 아니다 (Review가 꺼진 셸은 결정을 열 수 없다)
    func togglePanel() {
        if panelOpen {
            dismiss()
        } else if taskforceEnabled {
            // OA U3-41: 요청이 있으면 서버 순서의 첫 요청(가장 오래 기다린 요청), 없으면 마지막 화면
            if let first = taskforceQueue.first { openTaskforce(requestID: first.id) } else { openPanel(view) }
        } else if review != nil, reviewQueue.newest != nil {
            openNewestReview()
        } else {
            openPanel(view)
        }
    }

    func openPanel(_ view: View) {
        // Sessions는 Sessions 버튼이 있는 셸(새 Issues 화면 ∧ 로그인)에서만 열린다. 열어 둔 데스크톱 세션이 없는 `.claudeApp`은 Sessions로 연다 (⌥ Space의 마지막 화면)
        let view = view == .claudeApp && desktopPanelID == nil ? View.sessions : view
        guard view != .sessions || sessionsVisible else { return }
        // Chats가 없는 셸은 Chats 화면으로 열지 않는다 (⌥ Space의 마지막 화면 · 레일 · 키 어느 길로도). Assistant 창이 있는 셸도 패널은 Chats 화면을 열지 않는다
        guard view != .chats || (chatsEnabled && !windowsEnabled) else { return }
        // Review를 떠나면 그 결정에 대한 안내는 거둔다 (돌아오면 지금 상태가 말한다)
        if view != .review { review?.clearNotice() }
        if view == .review, review != nil, !(panelOpen && self.view == .review) { reviewPresentation += 1 }
        if view == .allWork, !(panelOpen && self.view == .allWork) { allWorkPresentation += 1 }
        // 왼쪽 패널(세션 보기)은 그 맥락 안에서만 산다: Sessions → 다른 화면 · 다른 화면 → Sessions로 가면 닫는다. 데스크톱 세션 보기는 Sessions · `.claudeApp` 밖으로 가면 닫는다
        if view != self.view {
            if view == .sessions || self.view == .sessions { sessionPanelID = nil }
            if view != .sessions, view != .claudeApp { desktopPanelID = nil }
        }
        self.view = view
        panelOpen = true
        menuOpen = false
        // 접었던 세션 패널이 다시 보이면(숨김 → 표시) 그 대화를 다시 읽는다. 세션 패널이 안 보이는 화면으로 가면 읽기 기록을 지운다
        loadPanelConversationIfNeeded()
        if view == .chats { onChatsOpened() }
        // All work로 들어오면 지금 들고 있는 응답이 처음 화면에 보인다: 아직 확정을 받지 않은 응답이면 그 표시 시점이다 (이미 받은 응답은 다시 받지 않는다)
        if view == .allWork || (view == .review && taskforceEnabled) { considerSummaryBaseline() }
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

    // MARK: On this Mac (OA 외부 세션 PR1)

    /// Sessions 패널에 On this Mac 절(이 Mac의 Claude 세션)이 있나: 새 Issues 화면(캡슐 레일) ∧ 목록이 만들어졌고(`BridgeFlag`) ∧ 로그인. 데스크톱 링도 같은 조건이다
    var externalSessionsVisible: Bool { issues != nil && externalSessions != nil && account != nil }

    /// 레일 첫 캡슐에 Sessions 버튼이 있나 (OA PR-D2, 계약 23장): 새 Issues 화면(캡슐 레일) ∧ 로그인. On this Mac 절이 없어도(`BridgeFlag` 꺼짐) Taskforce 세션은 이 패널에서 본다.
    /// 접힌 레일에서는 Sessions · `+`가 접힌다 (링만 남는다)
    var sessionsVisible: Bool { issues != nil && account != nil }

    // MARK: Open in Claude (F4: 그 세션을 데스크톱 앱에서 연다)

    /// 거절 줄(회색 한 줄)을 보이는 시간
    static let openNoticeSeconds: TimeInterval = 8
    /// 열기가 클릭 뒤의 훑기를 기다리는 동안 줄이 바쁜 채로 있는 최대 시간 (보안 재검토 P3)
    static let busyWaitCapSeconds: TimeInterval = 2

    /// 지금 거절 줄을 보이는 세션 (한 줄만). 사용자가 터미널을 닫고 다시 누르거나 시간이 지나면 사라진다
    private(set) var openNoticeSessionID: String?
    /// 열기(다시 확인 · 띄우기 · 거절 뒤 다시 훑기)가 도는 세션: 줄의 버튼이 누르는 즉시 "Opening…" · 비활성으로 보인다 (`externalLine`)
    private(set) var openingSessionIDs: Set<String> = []
    @ObservationIgnored private var openNoticeTimer: EdgeTimer?

    /// 줄의 Open in Claude.
    /// - **모델의 가드 (보안 검토 P3)**: CLI는 `Idle`인 데스크톱 출처 줄(`.available` + `claudeDesktop`)에만 닿는다. 그 밖은 — Running in Claude 줄(실측 2026-10-22: 이미 데스크톱 앱이 쥔 세션에 `--desktop --resume`을 하면
    ///   CLI가 "open in another terminal"로 거절하고 1로 끝난다) · 다른 상태 · 터미널 출처 줄 모두 — 줄을 그리는 쪽이 어떻게 하든 앱만 앞으로 가져온다.
    /// - **Idle 데스크톱 줄**: 누르는 즉시 버튼이 "Opening…"이 된다(비활성). 띄우기 **직전에** 그 세션의 쥠을 다시 보고(`recheck`) 쥔 곳이 있으면(또는 모르면) 띄우지 않는다. 비어 있으면 `claude --desktop --resume`:
    ///   `.opened`면 앱이 앞으로 오는 것은 `claude`가 하고, 목록은 뒤에서 다시 훑는다(줄이 곧 Running in Claude가 된다).
    ///   "다른 터미널에 열려 있다"는 거절은 스캔과 클릭 사이에 누가 쥐었다는 뜻이다: **클릭 뒤에 시작하는 훑기**가 끝나면 고친 줄로 정한다 — 이제 Claude 앱이 쥔 줄이면 앱만 앞으로(거절 줄 없음),
    ///   아니면 이미 승인된 "Running in Terminal"을 회색 한 줄로 8초 보인다. 그 밖의 실패(`claude` 없음 · 앱 없음 · 폴더 규칙 · 옛 버전 · 시간 초과 …)는 앱만 앞으로 가져온다.
    /// 같은 세션을 여는 중에 다시 누르면 무시한다 (끝나기를 기다릴 수 있게 Task를 돌려준다)
    @discardableResult
    func openInClaude(_ row: ExternalSessionRow) -> Task<Void, Never> {
        guard row.status == .available, row.client == .claudeDesktop else {
            _ = claudeApp.openClaudeApp()
            return Task {}
        }
        let id = row.id
        guard !openingSessionIDs.contains(id) else { return Task {} }
        openingSessionIDs.insert(id)
        clearOpenNotice()
        let folder = row.folderPath
        return Task { [weak self] in
            await self?.openIdleSession(id: id, folder: folder)
        }
    }

    private func openIdleSession(id: String, folder: String?) async {
        defer { openingSessionIDs.remove(id) }
        // 쥠을 다시 본다: 모르면(nil) 띄우지 않는다 (옛 동작으로 물러난다)
        guard let hold = await externalSessions?.recheck(id) else {
            _ = claudeApp.openClaudeApp()
            return
        }
        guard hold == .available else {
            await settleAfterHeld(id: id, hold: hold)
            return
        }
        switch await claudeApp.openSession(id: id, folder: folder) {
        case .opened:
            // 열렸다: 줄은 곧 실제 상태(Running in Claude)가 된다. 그 훑기가 끝날 때까지 줄은 계속 바쁘다 (빠른 두 번째 클릭이 `claude`를 또 띄우지 않게, 한도까지)
            await rescanWithinCap()
        case .openInAnotherTerminal:
            await settleAfterHeld(id: id, hold: .held(.terminal))
        case .unavailable:
            _ = claudeApp.openClaudeApp()
        }
    }

    /// 클릭 뒤에 시작하는 훑기(`refreshFresh`)가 끝나기를 기다린다, 단 `busyWaitCapSeconds`까지만 (보안 재검토 P3: 훑기가 멈춰도 줄이 영영 바쁘지 않게).
    /// 한도를 넘으면 기다림만 그만둔다: 훑기는 계속 돌고 끝나면 목록이 스스로 바뀐다. 한도 타이머는 모델의 `schedule`이라 시험이 가짜 시계로 흘린다
    private func rescanWithinCap() async {
        guard let store = externalSessions else { return }
        let latch = RescanLatch()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            latch.continuation = continuation
            latch.timer = schedule(Self.busyWaitCapSeconds) { latch.finish() }
            Task {
                await store.refreshFresh()
                latch.finish()
            }
        }
    }

    /// 훑기가 끝난 것과 한도가 지난 것 중 먼저 오는 쪽이 기다림을 한 번만 푼다
    @MainActor
    private final class RescanLatch {
        var continuation: CheckedContinuation<Void, Never>?
        var timer: EdgeTimer?

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            continuation.resume()
        }
    }

    /// 열기 직전의 확인이 쥔 곳을 찾았거나 CLI가 "다른 터미널"로 거절했다: 클릭 뒤에 시작하는 훑기가 끝나기를 기다려(한도까지) 고친 줄로 정한다 (이미 도는 훑기는 클릭 전 모습이다).
    /// 한도를 넘으면 지금 아는 것(확인 · 거절이 말한 쥠)으로 정하고, 훑기가 끝나면 줄이 스스로 바뀐다
    private func settleAfterHeld(id: String, hold: ExternalSessionStatus) async {
        await rescanWithinCap()
        // 데스크톱 앱이 쥐었다(확인이 말했거나 다시 훑은 줄이 말한다): 앱만 앞으로
        if hold == .held(.claudeApp) || externalSessions?.rows.first(where: { $0.id == id })?.status == .held(.claudeApp) {
            _ = claudeApp.openClaudeApp()
            return
        }
        // 터미널이 쥐었다: 줄에 승인된 말을 잠깐. 그 밖의 쥠 · 확인 못 함은 다시 훑은 줄이 제 상태로 바뀌어 말한다
        if hold == .held(.terminal) { showOpenNotice(for: id) }
    }

    private func showOpenNotice(for id: String) {
        openNoticeTimer?.cancel()
        openNoticeSessionID = id
        openNoticeTimer = schedule(Self.openNoticeSeconds) { [weak self] in self?.clearOpenNotice() }
    }

    private func clearOpenNotice() {
        openNoticeTimer?.cancel()
        openNoticeTimer = nil
        openNoticeSessionID = nil
    }

    /// 패널의 줄 글: 여는 중인 줄은 `isBusy`(버튼 글자 "Opening…" · 비활성은 줄 그림이 정한다), 방금 "다른 터미널에 열려 있다"고 막힌 쉬는 줄은 둘째 줄이 회색 "Running in Terminal" 한 줄
    func externalLine(_ row: ExternalSessionRow, now: Date) -> ExternalSessionLineContent {
        ExternalSessionLineText.make(
            row, now: now, notice: openNoticeSessionID == row.id ? ExternalSessionCopy.runningInTerminal : nil, busy: openingSessionIDs.contains(row.id)
        )
    }

    /// 레일의 Sessions · ⌘4: 패널에 Taskforce 세션과 이 Mac의 Claude 세션을 모두 연다 (Sessions 버튼이 없는 셸은 아무 일도 없다)
    func openSessions() {
        guard sessionsVisible else { return }
        openPanel(.sessions)
        readSessionsOnEntry()
    }

    /// 레일의 Sessions 버튼 · ⌘4 (계약 24장, 토글): Sessions가 이미 열려 있으면 패널을 닫고, 아니면 연다
    func toggleSessions() {
        guard sessionsVisible else { return }
        if panelOpen, view == .sessions {
            dismiss()
            return
        }
        openSessions()
    }

    /// 레일의 Projects(All work) 칸 · ⌘2 (계약 24장, 토글): Projects 첫 화면이 이미 열려 있으면 패널을 닫는다.
    /// 이슈 목록 · 상세처럼 쌓인 화면에서는 닫지 않고 Projects 첫 화면으로 간다 (그 화면의 칸을 누른 것이 아니다). 다른 화면이 열려 있으면 연다
    func toggleAllWork() {
        if panelOpen, view == .allWork {
            // 새 Issues 화면: 쌓인 화면이 아니면 닫는다. 노치 레일(옛 구성): 고른 행 · 검색어 · 필터(카드 포함)가 없을 때만 닫는다 —
            // 있으면 옛 동작대로 그것을 비우고 목록을 보인다 (`openAllWork`)
            let atFirstScreen = issues != nil
                ? !nav.canGoBack
                : currentID == nil && workFilter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !workFilter.hasActiveFilters && !filtersOpen
            if atFirstScreen {
                dismiss()
                return
            }
        }
        openAllWork()
    }

    /// 레일의 고정 칸을 눌렀다 (More는 카드가 따로 연다: 레일 컨트롤러가 열고 닫는다). 눌린 칸의 패널이 이미 열려 있으면 닫는다 (토글)
    func pressControl(_ control: Control) {
        switch control {
        case .allWork: toggleAllWork()
        case .chats: openChats()
        case .sessions: toggleSessions()
        case .more: break
        }
    }

    /// Open in Claude (그 세션을 데스크톱 앱에서 열고, 못 열면 앱만 앞으로): 시험은 가짜로 바꾼다
    @ObservationIgnored var claudeApp: any ClaudeAppOpening = LiveClaudeAppOpener()

    /// 목록이 보이는 동안만 훑는다 (패널 열림 ∧ Sessions 화면): 열면 10초마다 다시 보고, 닫히거나 다른 화면으로 가면 멈춘다
    @ObservationIgnored private var externalSessionsShowing = false

    private func externalSessionsPanelChanged() {
        let showing = panelOpen && view == .sessions && externalSessionsVisible
        guard showing != externalSessionsShowing else { return }
        externalSessionsShowing = showing
        if showing { externalSessions?.panelOpened() } else { externalSessions?.panelClosed() }
    }

    // MARK: Sessions 패널의 줄 · Claude 데스크톱 세션 보기 (OA PR-D2)

    /// Sessions의 Taskforce 줄을 눌렀다: 그 세션 패널이 Sessions 왼쪽에 선다 (이슈 상세의 Sessions 줄을 눌렀을 때와 같은 기존 세션 패널). 같은 줄을 다시 누르면 닫는다.
    /// 연 세션은 끝남(초록)이 내려간다. 왼쪽 패널은 하나라서 데스크톱 세션 보기는 닫힌다
    func openSessionRow(_ id: UUID) {
        guard issues != nil, panelOpen, view == .sessions else { return }
        desktopPanelID = nil
        sessionPanelID = sessionPanelID == id ? nil : id
        if sessionPanelID != nil {
            issues?.sessions.markOpened(id)
            Task { await issues?.sessions.refresh() }
        }
        loadPanelConversationIfNeeded()
    }

    /// 데스크톱 세션을 연 길: 레일의 링(`rail`)은 이슈 패널 없이 한 패널만 레일 옆에, Sessions의 줄(`list`)은 Sessions를 두고 그 왼쪽에
    enum DesktopOpenSource: Equatable {
        case rail
        case list
    }

    /// Claude 데스크톱 세션 보기(읽기 전용)를 연다. 연 세션은 끝남이 내려가고 · 보는 동안 끝나도 done이 되지 않고 · 그날 첫 열기는 지표 `claude_app_session_opened`(종류만)를 남긴다.
    /// Sessions가 열려 있으면 그 왼쪽에 서고(같은 줄을 다시 누르면 닫는다) 아니면 `.claudeApp` 화면으로 레일 옆 한 패널이 된다
    func openDesktopSession(_ id: String, from source: DesktopOpenSource) {
        guard desktop != nil, sessionsVisible else { return }
        sessionPanelID = nil
        if panelOpen, view == .sessions {
            if source == .list, desktopPanelID == id {
                desktopPanelID = nil
                return
            }
            desktopPanelID = id
        } else {
            desktopPanelID = id
            openPanel(.claudeApp)
        }
        desktop?.markOpened(id)
        claudeAppOpened?.opened()
    }

    /// 세션 보기의 Open in Claude: 이 Mac 목록에 그 세션의 줄이 있으면 줄의 단추와 같은 길(쉬는 데스크톱 줄만 그 세션을 열고 나머지는 앱만 앞으로), 아직 훑지 않았으면 앱만 앞으로
    @discardableResult
    func openDesktopInClaude(_ id: String) -> Task<Void, Never> {
        if let row = desktopRow(id) { return openInClaude(row) }
        _ = claudeApp.openClaudeApp()
        return Task {}
    }

    /// 데스크톱 세션 보기를 닫는다 (Esc · 같은 줄 다시 누름 · 다른 화면). `.claudeApp` 화면(레일 옆 한 패널)이었으면 패널째 접는다
    func closeDesktopSession() {
        desktopPanelID = nil
        if panelOpen, view == .claudeApp { dismiss() }
    }

    /// 데스크톱 세션 보기가 실제로 보인다: 패널이 열려 있고 열어 둔 세션이 있고 화면이 Sessions(왼쪽 패널) 또는 `.claudeApp`(레일 옆 한 패널)이다
    var desktopPanelShown: Bool { panelOpen && desktopPanelID != nil && (view == .sessions || view == .claudeApp) }

    /// 그 세션의 줄 (이 Mac 목록): 제목 · 폴더를 거기서 읽는다. 아직 훑지 않았으면 nil
    func desktopRow(_ id: String) -> ExternalSessionRow? {
        externalSessions?.rows.first { $0.id == id }
    }

    /// 레일 링 · 세션 보기 머리의 제목: 이 Mac 목록의 줄 제목(없으면 폴더 이름, 그것도 없으면 "Untitled"). 목록에 아직 없으면 에이전트 이름
    func desktopTitle(_ id: String) -> String {
        desktopRow(id).map(ExternalSessionLineText.title) ?? AgentMarkKind.claudeCode.accessibilityName
    }

    /// 머리 둘째 줄의 폴더 이름 (경로가 아니다, 엉뚱한 세션에 보내지 않게 하는 확인용): 목록의 줄 → 등록 파일의 작업 폴더
    func desktopFolderName(_ id: String) -> String? {
        guard let path = desktopRow(id)?.folderPath ?? desktop?.session(id: id)?.cwd else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// 열어 둔 세션이 바뀌었거나 패널이 보이게 · 숨게 됐다: 대화를 그 세션 것으로 맞추고, 라이브 꼬리는 보이는 동안만 읽고, 보고 있는 세션을 폴 모델에 알린다 (끝나도 done이 되지 않게)
    private func desktopPanelChanged() {
        guard desktop != nil || desktopConversation != nil else { return }
        if let id = desktopPanelID {
            if desktopConversation?.sessionID != id {
                desktopConversation?.stop()
                desktopConversation = makeConversation(id, desktop?.session(id: id)?.cwd ?? desktopRow(id)?.folderPath)
            }
        } else if desktopConversation != nil {
            desktopConversation?.stop()
            desktopConversation = nil
        }
        let shown = desktopPanelShown ? desktopPanelID : nil
        if shown != nil { desktopConversation?.start() } else { desktopConversation?.stop() }
        desktop?.setViewing(shown)
        // 입력창이 보이는 세션: 중계를 미리 띄워 두고, 접으면 쓰는 곳이 없어져 2분 뒤 끝난다 (교환을 따라가는 일은 패널을 닫아도 계속한다)
        if let previous = visibleChatID, previous != shown { desktopChat?.chat(for: previous).setVisible(false) }
        if let shown { desktopChat?.chat(for: shown).setVisible(true) }
        visibleChatID = shown
    }

    /// 데스크톱 세션의 상태나 이 Mac 목록(제목)이 바뀌었다 (컨트롤러가 관찰해서 부른다): 레일의 링을 다시 정한다.
    /// 레일에 오른 세션의 제목을 아직 모르면 이 Mac 목록을 한 번 훑는다 (5초에 한 번까지)
    func desktopChanged() {
        refreshSlots(at: clock())
        if externalSessionsVisible, desktop?.rail.contains(where: { desktopRow($0.id) == nil }) == true { externalSessions?.railExpanded() }
    }

    /// Chats: 레일의 Chats · ⌘3 (노치 레일만 — 캡슐 레일은 Chats 칸이 없다, 계약 24장). Assistant 창이 있으면 가장 앞 창을 앞으로 가져오고 없으면 연다 (패널은 그대로). 창이 없는 구성은 패널의 Chats로 마지막 대화로 돌아간다
    func openChats() {
        guard chatsEnabled, issues == nil else { return }
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
        if taskforceEnabled, view == .review { return TaskforceCopy.title }
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
        // 이슈를 열었다: 그 이슈의 끝남(초록)이 내려간다 (계약 23장, 열기 전까지만 남는다)
        markIssueOpened(id)
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
        // 이슈를 열었다: 그 이슈의 끝남(초록)이 내려간다
        markIssueOpened(id)
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

    /// SessionRow: 이슈 상세 왼쪽에 세션 패널 (같은 세션이면 닫고, 다른 세션이면 바꾼다). 이슈 상세 없이 열리지 않는다 — 세션은 이슈 상세의 Sessions 목록에서만 연다 (OA U3-45)
    func openSession(_ id: UUID) {
        guard issues != nil, panelOpen, view == .allWork, nav.detailID != nil else { return }
        sessionPanelID = sessionPanelID == id ? nil : id
        if sessionPanelID != nil {
            // 연 세션의 끝남(초록)이 내려간다
            issues?.sessions.markOpened(id)
            Task { await issues?.sessions.refresh() }
        }
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

    /// 세션 패널 창이 실제로 보인다: 이슈 패널이 이슈 상세로 열려 있거나(OA U2) Sessions가 열려 있고(OA PR-D2) 세션 패널이 열려 있다 (`EdgeShell.followSessionPanel`과 같은 조건)
    var sessionPanelShown: Bool { panelOpen && ((view == .allWork && nav.detailID != nil) || view == .sessions) && openSessionItem != nil }

    func closeSessionPanel() {
        sessionPanelID = nil
    }

    /// New session `+`: 새 Assistant 창 + 범위 칩 + 대상 메뉴. 칩: 지금 패널에 열린 것 (없으면 칩 없음)
    func newSession(from source: NewSessionSource) {
        guard issues != nil else { return }
        switch source {
        case .rail:
            onNewSession(openItem)
        }
    }

    /// Esc의 Issues 차례 (열린 메뉴는 컨트롤러가 먼저 닫는다): 세션 패널 → 이슈 상세(목록으로). 그 밖은 접는다. 처리했으면 true
    func escapeIssues() -> Bool {
        // 열린 확인 카드 · 후보 메뉴가 먼저다 (세션 패널을 닫기 전에)
        if onEscapeSessionOverlay() { return true }
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
        // 세션 패널은 이슈 상세 없이 열려 있지 않다 (목록 화면에서 열린 세션 패널은 다음 맞추기에서 닫힌다, OA U3-53). Sessions 패널은 이슈 상세 없이 세션 패널을 둔다 (OA PR-D2)
        if sessionPanelID != nil, nav.detailID == nil, view != .sessions { sessionPanelID = nil }
    }

    /// 세션 · 번호가 바뀌었다: 레일의 링을 다시 정하고 열어 둔 화면을 맞춘다
    func sessionsChanged() {
        refreshSlots(at: clock())
        reconcileIssues()
        loadPanelConversationIfNeeded()
        openedWhileViewing()
        sessionsChangedForTaskforce()
        // 새로 읽은 세션으로 열린 Resume 확인 카드를 맞춘다 (대상이 더는 external이 아니면 낡은 카드를 닫는다)
        if let issues, issues.sessions.hasRead { onSessionItemsChanged(issues.sessions.items) }
    }

    // MARK: Review (S4)

    /// Review 큐: 서버 순서 그대로 (`work.review`는 서버가 받았다고 답한 답을 이미 뺀 것이다, `NowStore.sections`).
    /// **Taskforce 대화가 켜진 구성에는 v1 Review 큐가 없다** (OA U3): 확인 요청은 v2 요청이 말하고(`taskforceQueue`) v1 목록은 그 본문(이유 · 기한 · 근거)의 재료일 뿐이다.
    /// 그래서 링 클릭(`openRailEntry`)이 어떤 이슈에서도 Taskforce 대화를 열지 않는다
    var reviewQueue: ReviewQueue { taskforceEnabled ? ReviewQueue([]) : ReviewQueue(work.review) }

    /// 지금 Review 페이지가 보이는 결정. 보던 id가 큐에 없으면 nil.
    /// Taskforce 대화에서는 보이는 요청이 확인 요청일 때 그 v1 항목이다 (본문 · 근거 · 답은 v1 경로 그대로, OA U3-25)
    var shownReview: ActionSummary? {
        if taskforceEnabled {
            guard let request = shownTaskforceRequest, request.kind == .confirm else { return nil }
            return work.review.first { $0.id == request.actionID }
        }
        return reviewID.flatMap { reviewQueue.item($0) }
    }

    /// 본문에 무엇을 보일지: 받은 목록이 없으면 "결정이 없다"고 말하지 않는다
    var reviewScreen: ReviewScreen { ReviewScreen.of(load: work.load, hasDecision: shownReview != nil) }

    /// 레일에서 "지금 보는 일"로 표시할 id: Review 페이지가 보이면 그 결정, 아니면 All work에서 연 일
    var railCurrentID: UUID? { view == .review ? reviewID : currentID }

    /// 레일의 일을 누름. 세션의 질문을 기다리는 링이면 그 이슈 상세 + 그 세션 패널 + 카드 포커스 (OA D4b-m-1, D4bm-57: 질문은 Review에 없고 그 세션에서만 답한다).
    /// S4가 켜져 있고 Needs-you 링이면 그 Review 항목 (그 밖의 링은 그 일, 기존 동작 그대로)
    func openRailEntry(_ entry: RailEntry) {
        // Claude 데스크톱 세션의 링: 이슈 패널 없이 그 세션 보기 한 패널 (OA PR-D2, DR-S1d). Taskforce 링과 똑같은 모양이고 이름 · 툴팁이 말한다
        if case .claudeApp(let sessionID) = entry.source {
            openDesktopSession(sessionID, from: .rail)
            return
        }
        // 링을 눌러 연다: 그 이슈의 끝남(초록)이 내려간다 (계약 23장, 열 때까지 남는다)
        markIssueOpened(entry.id)
        if entry.kind == .needsYou, questions != nil, let waiting = issues?.sessions.sessions(of: [entry.id]).first(where: { $0.ring == .needsYou }) {
            openQuestion(session: waiting.id)
            return
        }
        // 새 Issues 화면: needs-you가 세션의 질문이라 Review 큐에 그 이슈가 없으면 다른 이슈의 Review를 열지 않고 그 이슈의 상세를 연다.
        // Taskforce 대화가 켜진 구성(OA U3)은 늘 그 이슈의 상세다: 링은 세션이고 Taskforce 요청은 bell로 간다 (링 클릭이 대화를 열지 않는다)
        if review != nil, !taskforceEnabled, entry.kind == .needsYou, issues == nil || reviewQueue.contains(entry.id) {
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

    /// ⌘1 (OA U2b): 답할 항목이 있으면 가장 새 Review 항목. 없고 바뀐 것(복귀 요약)만 있으면 그 구성에서 요약이 그려지는 곳, 둘 다 없으면 아무것도 하지 않는다 (빈 "No decisions waiting" 화면을 열지 않는다).
    /// 목록을 아직 못 받았거나(읽는 중 · 오프라인 · 읽기 실패) 큐가 비었는지 모르면 Review가 그 사정을 말하도록 연다.
    /// 복귀 요약이 그려지는 곳: 새 Issues 화면이 꺼진 구성(Release 표면 포함)은 All work 위 카드뿐이다. U2 + C3에서는 Review에도 Projects에도 요약이 없다 (U2 계약 10장 2, Review 안 카드는 D4b-m): 열 곳이 없어 아무것도 하지 않는다
    func openNewestReview() {
        guard review != nil else { return }
        // Taskforce 대화: 늘 대화를 연다 — 요청이 있으면 서버 순서 첫 요청, 없으면 빈 상태 + 요약, 못 읽었으면 그 사정 (OA U3-40)
        if taskforceEnabled {
            openTaskforce()
            return
        }
        if let newest = reviewQueue.newest {
            reviewID = newest.id
            openPanel(.review)
        } else if case .empty = reviewScreen {
            guard issues == nil, summary?.summary?.hasChangesToClear == true else { return }
            openAllWork()
        } else {
            reviewID = nil
            openPanel(.review)
        }
    }

    /// ← →: 큐에서 한 칸 (끝에서 돌지 않는다). 항목은 id로 옮긴다
    func stepReview(_ offset: Int) {
        if taskforceEnabled {
            stepTaskforce(offset)
            return
        }
        guard review != nil, view == .review, let id = reviewID, let next = reviewQueue.neighbor(of: id, offset: offset) else { return }
        reviewID = next
    }

    /// 목록이 바뀐 뒤 보던 결정을 맞춘다: 보던 id가 그대로 있으면 순서가 바뀌어도 그 항목, 빠졌으면 그 뒤를 이은 항목(같은 index의 다른 항목이 아니라), 보던 것이 없으면 가장 새 항목
    private func reconcileReview(previous: [UUID]) {
        guard review != nil, !taskforceEnabled else { return }
        reviewID = reviewQueue.resolving(reviewID, previous: previous)
    }

    /// Taskforce 대화가 켜진 구성은 이 대화 저장소의 연결도 본다: 저장소가 오프라인을 먼저 받고 `/now` 화면(`reviewScreen`)이 아직 모르는 사이에도 막는다
    /// (오래된 카드의 클릭 콜백이 이 빈틈에 도착해도 접수 · 전송하지 않는다). 대화가 꺼진 구성은 지금 규칙 그대로다
    private var taskforceAllowsAnswer: Bool { !taskforceEnabled || taskforceScreen.canAnswer }

    /// 사용자가 고른 답 하나 (클릭 · 1/2 키). `id`는 사용자가 본 항목의 id다: 지금 보이는 결정이 아니면(큐가 바뀌어 빠졌거나 다른 항목이 보임) 아무것도 하지 않는다.
    /// 오프라인이거나 Review가 보이지 않으면 보내지 않는다 (나중에 보내려고 모아 두지 않는다).
    /// **받는 이 동기 경계에서** 계정 token · 항목 · 이 방문(`reviewPresentation`)을 잡고, 예약된 작업이 실제로 보내기 직전에 다시 본다 (`ReviewDesk.send`):
    /// 그 사이 계정이 바뀌었거나(같은 UUID 재로그인 포함) 패널이 닫히고 화면이 옮겨지고 항목이 큐에서 빠지거나 더는 보이는 결정이 아니면 쓰기 0이다
    @discardableResult
    func answer(_ answer: ReviewAnswer, for id: UUID) -> Task<ReviewWriteResult, Never>? {
        guard let review, panelOpen, view == .review, reviewScreen.canAnswer, taskforceAllowsAnswer, shownReview?.id == id,
              let ticket = review.begin(answer, for: id) else { return nil }
        let presentation = reviewPresentation
        return Task { [weak self] in
            let result = await review.send(ticket) {
                guard let self else { return false }
                return self.panelOpen && self.view == .review && self.reviewPresentation == presentation
                    && self.reviewScreen.canAnswer && self.taskforceAllowsAnswer && self.shownReview?.id == id
            }
            // 서버가 받은 답이면 복귀 요약의 `Needs your answer`가 낡았을 수 있다: 서버의 지금 상태를 다시 읽는다 (읽기일 뿐, C3가 켜졌을 때만)
            if result == .applied {
                await self?.summary?.refresh()
                // Taskforce 대화: 답한 확인 요청이 빠진 v2 목록을 다시 읽는다 (OA U3-20 "내 답 뒤")
                await self?.taskforceStore?.refresh()
            }
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
        // Taskforce 대화의 요약 줄은 변화만 말한다: 그 작업(이슈 상세)을 연다. 결정은 요청 카드가 말한다
        if taskforceEnabled {
            open(itemID: actionID)
            return
        }
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
        // Taskforce 대화: 같은 규칙을 이 대화의 **방문**(`reviewPresentation`)에 건다 — 읽음 처리일 뿐 요청을 해결하지 않는다 (OA U3-28)
        if taskforceEnabled {
            guard let summary, taskforceConversationOpen, taskforceScreen.drawsSummary, let ticket = summary.beginClear() else { return nil }
            let presentation = reviewPresentation
            return Task { [weak self] in
                await summary.sendClear(ticket) {
                    guard let self else { return false }
                    return self.taskforceConversationOpen && self.reviewPresentation == presentation && self.taskforceScreen.drawsSummary
                }
            }
        }
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
        // Taskforce 대화: 대화가 그 요약을 **실제로 그릴 때만**, 이 방문(`reviewPresentation`) 안에서 한 번 (OA U3-28 · 51)
        if taskforceEnabled {
            guard let summary, drawsSummary, taskforceConversationOpen, let ticket = summary.beginBaseline() else { return nil }
            let presentation = reviewPresentation
            return Task { [weak self] in
                await summary.sendBaseline(ticket) {
                    guard let self else { return false }
                    return self.drawsSummary && self.taskforceConversationOpen && self.reviewPresentation == presentation
                }
            }
        }
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
    var drawsSummary: Bool { summary != nil && (issues == nil || (taskforceEnabled && taskforceScreen.drawsSummary)) }

    /// 복귀 요약 Try again
    func retrySummary() {
        guard let summary else { return }
        Task { await summary.refresh() }
    }

    /// Esc: 안쪽 것(열린 필터 카드 · Chats의 대화 목록)을 먼저 닫고, 그다음 패널을 접는다 (디자인 Focus and keys)
    func escape() {
        // 레일 옆 한 패널(데스크톱 세션 보기)은 Esc가 패널째 접는다. Sessions 왼쪽의 세션 보기는 Esc가 먼저 그것만 닫는다 (OA PR-D2)
        if panelOpen, view == .claudeApp {
            // 옆줄이 열려 있으면 Esc가 먼저 그것만 접는다 (꼬리 → 목록 → 접힘 → 패널)
            if onEscapeDesktopPane() { return }
            dismiss()
            return
        }
        if panelOpen, view == .sessions, desktopPanelID != nil || sessionPanelID != nil {
            if desktopPanelID != nil {
                if onEscapeDesktopPane() { return }
                desktopPanelID = nil
            } else if !onEscapeSessionOverlay() {
                sessionPanelID = nil
            }
            return
        }
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
        // 포인터가 레일에 없으면 바로 숨는다 (호버로 펼친 상태가 아니었으면). ⋯가 포커스를 받으러 가는 중이면 받은 뒤 평소 시간으로 접힌다
        if !pointerInside, moreFocusPending == nil {
            railHovered = false
        }
    }

    // MARK: More 메뉴

    /// More 카드가 닫혔다 (고름 · Esc · 바깥 클릭 · 키를 잃음): 메뉴 표시를 거두고 ⋯가 접근성 포커스를 받게 한다.
    /// 레일은 ⋯가 포커스를 받을 때까지 펼친 채 둔다 (포인터가 카드 위나 밖에 있어도: 먼저 접히면 ⋯ 칸이 사라져 돌려줄 곳이 없다).
    /// 받은 뒤에는 평소의 떠남 시간으로 접힌다. 끝내 받지 못해도 상한(`moreFocusHoldLimit`)이 풀어 준다
    func moreCardClosed() {
        menuOpen = false
        moreFocusSerial += 1
        moreFocusPending = moreFocusSerial
        moreFocusHold?.cancel()
        moreFocusHold = schedule(Self.moreFocusHoldLimit) { [weak self] in
            guard let self else { return }
            self.moreFocusHold = nil
            self.moreFocusPending = nil
            self.leaveIfIdle()
        }
    }

    /// ⋯ 칸 뷰가 접근성 포커스를 주었다 (⋯ 칸이 그려져 있을 때만 부른다)
    func moreFocusLanded(_ serial: Int) {
        moreFocusLandedSerial = serial
        guard moreFocusPending == serial else { return }
        moreFocusPending = nil
        moreFocusHold?.cancel()
        moreFocusHold = nil
        leaveIfIdle()
    }

    /// 붙잡던 일이 끝났다: 포인터가 레일에 없고 패널도 메뉴도 없으면 평소의 떠남 시간 뒤에 접는다
    private func leaveIfIdle() {
        guard !pointerInside, !panelOpen, !menuOpen else { return }
        scheduleLeave()
    }

    /// 노치 레일의 기본 메뉴(`NSMenu`)가 열리고 닫혔다. 닫히면 포인터가 레일 밖일 때 바로 접는다 (카드는 `moreCardClosed`)
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
        // 알던 계정이 떠났다(로그아웃 · 다른 계정): 그 계정의 끝남 표시는 이 계정에 없다 (저장본은 `AccountScope`가 비운다). 처음 로그인(앱을 다시 켠 뒤)은 저장해 둔 것을 그대로 둔다
        let hadAccount = self.account != nil
        self.account = account
        if hadAccount {
            recentlyDone = [:]
            carriedDone = [:]
            orphanTried = [:]
            // 마지막으로 저장한 표시의 사본도 비운다: 남기면 새 계정이 같은 표시를 만들었을 때 "바뀌지 않았다"며 저장하지 않는다
            savedIssueDone = nil
            // 세션 보기가 이 Mac에 둔 일 목록 판도 앞 계정의 것이다 (보안 P3-1)
            backgroundSessions?.leave()
            SessionMarkdownCache.shared.removeAll()
        }
        claimDoneStores(for: account)
        workFilter = WorkFilter()
        filtersOpen = false
        currentID = nil
        hoveredID = nil
        reviewID = nil
        taskforceShownID = nil
        taskforcePreviousIDs = []
        taskforceSessionSignature = [:]
        taskforceConfirmationIDs = []
        nav.reset()
        sessionPanelID = nil
        desktopPanelID = nil
        pins = account.map { pinStore.load(account: $0) } ?? WorkPins()
        // Sessions · 데스크톱 세션 보기는 로그인한 사용자에게만 있다: 열려 있던 화면은 All work로 돌아간다
        if view == .sessions || view == .claudeApp { view = .allWork }
        externalSessionsPanelChanged()
    }

    // MARK: 데이터

    /// 목록 · run이 바뀔 때마다. 레일의 칸은 남아 있는 일의 순서를 지킨다 (`RailOrdering`)
    func update(_ work: EdgeWorkSnapshot) {
        let now = clock()
        let previousReview = self.work.review.map(\.id)
        let previousWork = self.work
        let wasOnRail = Set(slots.filter { $0.kind != .done }.map(\.id))
        let doneIDs = Set(work.doneToday.map(\.id))
        let liveIDs = Set(work.review.map(\.id)).union(work.working)
        // 레일에 있던 일이 지금 끝남 → Done (옛 레일은 3초, 새 Issues 화면은 열어 볼 때까지)
        for id in wasOnRail where doneIDs.contains(id) && !liveIDs.contains(id) && recentlyDone[id] == nil {
            recentlyDone[id] = now
        }
        if doneUntilOpened {
            // 새 일이 시작하면 그 일의 끝남은 새 상태가 대신한다. 목록을 읽은 뒤에는 다시 열린 일(To Do · In Progress)의 표시를 지운다 — **더는 끝난 일이 아니다**.
            // 오늘 끝난 일에서 빠졌어도(자정이 지났거나 다음 날 다시 켰다) 아직 끝난 일의 표시는 사용자가 열어 볼 때까지 남긴다 (읽기 전에는 저장해 둔 것을 그대로 둔다)
            for id in liveIDs where recentlyDone[id] != nil { recentlyDone[id] = nil }
            if case .loaded = work.load {
                let reopened = Set(work.open.map(\.id))
                recentlyDone = recentlyDone.filter { !reopened.contains($0.key) }
            }
            // 마지막으로 본 그 일의 모습: 오늘 끝난 일에서 빠져도 링의 제목 · 상태를 그릴 수 있게 메모리에만 둔다 (다시 켜면 저장해 둔 표시만 남는다)
            for action in work.doneToday where recentlyDone[action.id] != nil { carriedDone[action.id] = action }
            carriedDone = carriedDone.filter { recentlyDone[$0.key] != nil }
            persistIssueDone()
            resolveOrphanDone(work, now: now)
        }
        self.work = work
        reconcileReview(previous: previousReview)
        refreshSlots(at: now)
        reconcileIssues()
        openedWhileViewing()
        workChangedForTaskforce(previous: previousWork)
    }

    /// Done 3초가 지난 일을 뺀다 (옛 레일)
    func expireDone() {
        refreshSlots(at: clock())
    }

    /// 끝난 링(초록)이 열어 볼 때까지 남는 셸인가: 새 Issues 화면(캡슐 레일) ∧ 끝남 저장소가 있다 (계약 23장). 아니면 지금처럼 3초다
    private var doneUntilOpened: Bool { issues != nil && railDone != nil }
    /// 마지막으로 저장한 이슈의 끝남 표시 (바뀔 때만 쓴다)
    @ObservationIgnored private var savedIssueDone: [UUID: Date]?
    /// 끝남 표시가 있는 이슈의 마지막으로 본 모습 (메모리에만: 오늘 끝난 일에서 빠진 뒤에도 링을 그린다)
    @ObservationIgnored private var carriedDone: [UUID: ActionSummary] = [:]

    /// 로그인한 계정이 끝남 표시의 주인인지 가린다 (보안 P3-1, 고정을 계정별로 가지치기하는 것과 같다): 저장본의 주인이 이 계정이 아니면(다른 계정이거나 모르면) 이 계정의 표시가 아니라서
    /// 저장본과 되살린 표시를 모두 비운다. 그 뒤 이 계정을 주인으로 적는다. Claude 데스크톱 표시도 같은 규칙이다
    private func claimDoneStores(for account: UUID?) {
        guard let account else { return }
        if doneUntilOpened, let railDone {
            if railDone.load().owner != account {
                railDone.clear()
                recentlyDone = [:]
                carriedDone = [:]
                orphanTried = [:]
                savedIssueDone = nil
                issues?.sessions.discardRestoredDone()
            }
            railDone.setOwner(account)
        }
        desktop?.adopt(account: account)
        // 세션 보기의 열어 본 시각 저장본도 같은 규칙이다 (주인이 이 계정이 아니면 비운다, 보안 P3-1)
        backgroundSessions?.adopt(account: account)
    }

    /// 주인이 없는 저장본에는 지금 계정을 주인으로 찍는다: 계정이 바뀔 때 "떠남"(저장본 비움)이 `claimDoneStores`(주인 적기)보다 늦게 와 도장이 지워졌어도
    /// 그 뒤에 쓰는 표시는 주인을 가진다 (순서와 상관없이 맞다). 다른 계정의 주인은 덮어쓰지 않는다
    private func persistIssueDone() {
        guard doneUntilOpened, let railDone else { return }
        let current = recentlyDone
        let account = account
        guard current != (savedIssueDone ?? railDone.load().issues) else { return }
        savedIssueDone = current
        railDone.update {
            $0.issues = current
            if $0.owner == nil { $0.owner = account }
        }
    }

    /// 표시만 남은 이슈를 다시 읽는 간격 (읽지 못했을 때)
    static let orphanRetryInterval: TimeInterval = 60
    /// 이슈를 마지막으로 읽어 본 때 · 읽는 중인 이슈
    @ObservationIgnored private var orphanTried: [UUID: Date] = [:]
    @ObservationIgnored private var orphanInFlight: Set<UUID> = []

    /// 다시 켠 뒤 표시는 있는데 어느 목록에도 없는 이슈(오늘 끝난 일에서 빠졌고 이 실행에서 본 적도 없다): 그 이슈를 id로 읽는다 (기존 RLS 읽기, 제목은 저장하지 않는다).
    /// 아직 끝난 이슈면 링을 제목과 함께 되살리고(메모리에만), 다시 열렸거나 지워졌거나 취소했으면 표시를 버리고, 읽지 못하면 표시를 두고 `orphanRetryInterval` 뒤에 다시 읽는다.
    /// 읽는 사이 계정이 바뀌었으면 그 결과를 쓰지 않는다
    private func resolveOrphanDone(_ work: EdgeWorkSnapshot, now: Date) {
        guard doneUntilOpened, case .loaded = work.load else { return }
        let known = Set(work.doneToday.map(\.id)).union(work.open.map(\.id)).union(work.review.map(\.id)).union(work.working).union(carriedDone.keys)
        let owner = account
        for id in recentlyDone.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !known.contains(id) && !orphanInFlight.contains(id) {
            if let tried = orphanTried[id], now.timeIntervalSince(tried) < Self.orphanRetryInterval { continue }
            orphanTried[id] = now
            orphanInFlight.insert(id)
            let lookup = lookupFinishedIssue
            Task { @MainActor [weak self] in
                let result = await lookup(id)
                guard let self else { return }
                self.orphanInFlight.remove(id)
                guard self.account == owner, self.recentlyDone[id] != nil else { return }
                switch result {
                case .finished(let summary):
                    self.carriedDone[id] = summary
                    self.refreshSlots(at: self.clock())
                case .notFinished, .gone:
                    self.recentlyDone[id] = nil
                    self.carriedDone[id] = nil
                    self.persistIssueDone()
                    self.refreshSlots(at: self.clock())
                case .unknown:
                    break
                }
            }
        }
    }

    /// 이슈를 열었다 (링 · 목록 · 상세): 그 이슈의 끝남(v1 run의 끝 · 그 이슈 세션들의 끝)을 지운다. 같은 완료는 다시 오르지 않고 새 일이 끝나야 다시 초록이다.
    /// 새 Issues 화면의 "열 때까지" 셸에서만 뜻이 있다
    func markIssueOpened(_ id: UUID) {
        guard doneUntilOpened else { return }
        let sessionIDs = Set(issues?.sessions.sessions(of: [id]).map(\.id) ?? [])
        if !sessionIDs.isEmpty { issues?.sessions.markOpened(sessionIDs) }
        if recentlyDone.removeValue(forKey: id) != nil {
            carriedDone[id] = nil
            persistIssueDone()
            refreshSlots(at: clock())
        }
    }

    /// 지금 보고 있는 것(이슈 상세 · 세션 패널)은 끝나도 초록으로 남기지 않는다: 보고 있으니 연 것이다
    private func openedWhileViewing() {
        guard doneUntilOpened, panelOpen else { return }
        if view == .allWork, let id = nav.detailID, recentlyDone[id] != nil || sessions(of: id).contains(where: { $0.ring == .done }) {
            markIssueOpened(id)
        }
        if sessionPanelShown, let item = openSessionItem, item.ring == .done { issues?.sessions.markOpened(item.id) }
    }

    private func refreshSlots(at now: Date) {
        if !doneUntilOpened { recentlyDone = recentlyDone.filter { now.timeIntervalSince($0.value) < TFMotion.doneHold } }
        let entries = Self.entries(
            work, recentlyDone: recentlyDone, sessions: issues?.sessions.items, confirmRequestsRing: !taskforceEnabled, untilOpened: doneUntilOpened,
            carriedDone: carriedDone.values.sorted { $0.id.uuidString < $1.id.uuidString }
        ) + desktopEntries()
        live = entries
        slots = RailOrdering.slots(previous: slots.map(\.id), entries: entries)
        if let hoveredID, !slots.contains(where: { $0.id == hoveredID }) { self.hoveredID = nil }
        scheduleDoneExpiry(now: now)
    }

    /// Claude 데스크톱 앱에 열린 세션의 링 (OA PR-D2, DR-S1c): Taskforce 세션 링과 같은 캡슐 · 같은 순서 · 용량 규칙을 나눠 쓴다. 업무 상태가 없어 이름 · 툴팁은 "제목 · 활동"이다
    private func desktopEntries() -> [RailEntry] {
        guard externalSessionsVisible, let desktop else { return [] }
        return desktop.rail.compactMap { entry in
            guard let uuid = UUID(uuidString: entry.id) else { return nil }
            let kind: ActivityRing.Kind
            let activity: String
            switch entry.kind {
            case .running: (kind, activity) = (.running, ClaudeAppCopy.runningInClaude)
            case .needsYou(.approval): (kind, activity) = (.needsYou, ClaudeAppCopy.needsApproval)
            case .needsYou(.answer): (kind, activity) = (.needsYou, ClaudeAppCopy.needsAnswer)
            case .done: (kind, activity) = (.done, AgentSessionRules.done)
            }
            return RailEntry(id: uuid, title: desktopTitle(entry.id), kind: kind, state: nil, activity: activity, source: .claudeApp(sessionID: entry.id))
        }
    }

    private func scheduleDoneExpiry(now: Date) {
        doneTimer?.cancel()
        doneTimer = nil
        guard !doneUntilOpened else { return }
        guard let earliest = recentlyDone.values.min() else { return }
        let delay = max(0, TFMotion.doneHold - now.timeIntervalSince(earliest))
        doneTimer = schedule(delay) { [weak self] in self?.expireDone() }
    }

    /// 지금 레일에 오를 수 있는 일: 확인 요청(needs you) · run이 도는 일(running · stop requested) · 막 끝난 일(done).
    /// `sessions`가 있으면(새 Issues 화면) 링 하나 = 이슈 하나다: 그 이슈의 v1 링과 닫히지 않은 세션들의 링 중 먼저인 것 (needs-you → unreachable → stopping → running → done → waiting).
    /// 세션만 있는 이슈(v1 run 없이 세션이 돈다)도 오른다. idle 세션은 링이 아니다
    /// `confirmRequestsRing`: v1 확인 요청이 이슈 링의 needs-you가 되나. **Taskforce 대화가 켜지면 아니다** — 확인 요청은 bell로 가고 링은 세션의 질문만 말한다 (DS "Two kinds of Needs you", OA U3-15)
    /// `untilOpened`: 끝난 링이 열어 볼 때까지 남는 셸이다 — 말이 "Done"이다 ("Done just now"는 링이 몇 시간 남으면 거짓이다, DZ RL3)
    /// `carriedDone`: 오늘 끝난 일에서 빠졌지만(자정이 지났다) 표시가 남은 일의 마지막으로 본 모습 — 열어 볼 때까지 남는 셸에서만 링으로 그린다
    static func entries(
        _ work: EdgeWorkSnapshot, recentlyDone: [UUID: Date], sessions: [AgentSessionItem]? = nil, confirmRequestsRing: Bool = true, untilOpened: Bool = false,
        carriedDone: [ActionSummary] = []
    ) -> [RailEntry] {
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
                // 3초 모드의 활동 글 (링의 이름은 "Done"이다: `ActivityRing.Kind.done`)
                entries.append(RailEntry(id: action.id, title: action.title, kind: .done, state: .done, activity: AgentSessionRules.doneJustNow))
            }
            return entries
        }
        var entries: [RailEntry] = []
        var seen = Set<UUID>()
        func add(_ action: ActionSummary, v1: AgentSessionRing?, state: TaskStatusMark.State) {
            guard seen.insert(action.id).inserted else { return }
            let mine = AgentSessionRules.sessions(of: [action.id], in: sessions)
            guard let ring = AgentSessionRules.issueRing(v1: v1, sessions: mine) else { return }
            entries.append(RailEntry(
                id: action.id, title: action.title, kind: ActivityRing.Kind(ring), state: state, activity: ring.railActivity ?? (ring == .done ? (untilOpened ? AgentSessionRules.done : AgentSessionRules.doneJustNow) : nil)
            ))
        }
        // 확인 요청의 이슈도 세션의 링은 가진다 (v1 needs-you만 빠진다)
        for action in work.review { add(action, v1: confirmRequestsRing ? .needsYou : nil, state: TaskStatusMark.State(.review)) }
        for action in work.open {
            let v1: AgentSessionRing? = work.working.contains(action.id) ? (work.stopping.contains(action.id) ? .stopping : .running) : nil
            add(action, v1: v1, state: TaskStatusMark.State(TaskGroup.open(action)))
        }
        for action in work.doneToday where recentlyDone[action.id] != nil { add(action, v1: .done, state: .done) }
        if untilOpened {
            // `add`가 이미 오른 이슈(오늘 끝난 일에도 있는)를 거른다
            for action in carriedDone where recentlyDone[action.id] != nil { add(action, v1: .done, state: .done) }
        }
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

// MARK: Taskforce (U3)

/// Taskforce 대화 (OA U3): 게이트(`EdgeSurfaces.taskforceConversation`) 안에서만 산다. 레일 첫 캡슐의 bell, Review 패널을 대신하는 대화, 서버 순서 첫 요청으로 가는 ⌘1 · ⌥Space.
/// 판정 · 순서는 서버가 정한 그대로이고 앱은 다시 정렬하지 않는다. 요청은 안정 id로 가리키고, 여는 것 · 읽는 것 · 단계를 옮기는 것 · Clear는 답이 아니다.
extension EdgeShellModel {
    /// 레일 bell · 대화를 여는 키 (⌘1)
    static let taskforceShortcut = "⌘1"

    /// 이 셸에 Taskforce 대화가 있나: 새 Issues 화면 + Review(S4) + 복귀 요약(C3)이 모두 켜진 구성뿐 (OA U3-01). 꺼지면 모든 것이 지금 그대로다
    var taskforceEnabled: Bool { taskforceGate && issues != nil && review != nil && summary != nil }

    var taskforceStore: TaskforceRequestStore? { taskforceEnabled ? issues?.taskforce : nil }

    // MARK: 요청

    /// 지금 보일 요청 (서버 순서 그대로). 재료(v1 확인 요청 · 세션 · 충돌 상세)를 아직 읽는 중이면 그 요청은 기다린다
    var taskforceVisible: TaskforceVisibleRequests {
        guard let store = taskforceStore, let issues else { return .none }
        return store.visible(
            confirmable: Set(work.review.map(\.id)), knownSessions: Set(issues.sessions.items.map(\.id)),
            confirmationsKnown: { if case .loaded = work.load { true } else { false } }(), sessionsKnown: issues.sessions.hasRead
        )
    }

    var taskforceQueue: TaskforceRequestQueue { TaskforceRequestQueue(taskforceVisible.requests) }

    /// 지금 대화가 보이는 요청
    var shownTaskforceRequest: TaskforceRequest? {
        let queue = taskforceQueue
        return taskforceShownID.flatMap { queue.request($0) }
    }

    /// 대화 본문에 무엇을 보일지: 응답이 없으면 비었다고 말하지 않는다
    var taskforceScreen: TaskforceScreen {
        guard let store = taskforceStore else { return .blank }
        let visible = taskforceVisible
        return TaskforceScreen.of(
            hasResponse: store.response != nil, readProblem: store.screenProblem, trustworthy: store.isTrustworthy(visible),
            hasRequest: !visible.requests.isEmpty, deferred: visible.deferred
        )
    }

    /// Taskforce 대화가 보이는 중이다
    var taskforceConversationOpen: Bool { taskforceEnabled && panelOpen && view == .review }

    // MARK: bell · 레일

    /// 캡슐 레일의 셋째 캡슐 칸(Projects · Chats · More)이 칠해지나 (OA U3). 호버는 늘 칠한다. 칠해진 칸이 곧 "지금 여기"이므로 **하나만** 칠해진다:
    /// 패널이 열려 있으면 그 화면의 칸 하나(Taskforce 대화는 bell이 칠해지고 셋째 캡슐은 하나도 안 칠해진다)이고, Assistant 창이 앞에 있다는 이유의 Chats 칠은 패널이 닫혀 있을 때만이다 (검토 1)
    func railControlHighlighted(_ control: Control) -> Bool {
        if control == .more { return menuOpen || hoveredControl == .more }
        // More 카드가 열려 있는 동안은 ⋯만 칠해진다 (열린 화면의 칸 · 호버도 칠하지 않는다. 카드가 닫히면 선택은 그대로 돌아온다)
        if menuOpen { return false }
        if hoveredControl == control { return true }
        if control == .chats, windowsEnabled, assistantWindowFront, !panelOpen { return true }
        guard panelOpen else { return false }
        switch control {
        case .allWork: return view == .allWork && currentID == nil
        case .chats: return view == .chats
        case .sessions: return view == .sessions
        case .more: return false
        }
    }

    /// 세션 링이 칠해지나: 호버, 또는 패널이 그 일을 보여 주는 중 (데스크톱 링은 그 세션 보기가 열려 있는 중)
    func railRingLit(_ id: UUID) -> Bool {
        if menuOpen { return false }
        if id == hoveredID || (panelOpen && id == railCurrentID) { return true }
        return desktopPanelShown && desktopPanelID.flatMap { UUID(uuidString: $0) } == id
    }

    /// bell의 호버 칠 (대화가 열려 있을 때의 칠은 bell 자체의 `selected`다: `railBellSelectionShown`)
    var railBellHoverLit: Bool { !menuOpen && hoveredBell }

    /// 열린 대화의 bell 칠을 그리나
    var railBellSelectionShown: Bool { !menuOpen }

    /// New session `+`의 호버 칠
    var railPlusLit: Bool { !menuOpen && hoveredPlus }

    /// 레일 첫 캡슐의 bell (없으면 nil): 보이는 요청이 있거나 대화가 열려 있을 때만. 울림 = 보이는 요청 > 0 (변화만으로는 울리지 않는다)
    var taskforceBell: TaskforceBell? {
        TaskforceBellRules.bell(requestCount: taskforceQueue.count, conversationOpen: taskforceConversationOpen, enabled: taskforceEnabled)
    }

    /// 캡슐 레일의 상태: 링 0 · 요청 0 · 펼침 아님 = 쉼, 펼침 아님 = 접힘, 호버 120ms · 패널 열림 = 펼침
    var railMode: EdgeRailCapsuleLayout.Mode {
        if isExpanded { return .expanded }
        return notch.isEmpty && taskforceBell == nil ? .rest : .compact
    }

    /// 지금의 캡슐 레이아웃 (그리기와 포인터 판정이 같은 값)
    var capsuleLayout: EdgeRailCapsuleLayout {
        EdgeRailCapsuleLayout(mode: railMode, bell: taskforceBell != nil, compactRingCount: notch.count, ringCount: slots.count, controls: controls, sessionsButton: sessionsVisible)
    }

    // MARK: 열기 · 단계 · 읽기

    /// ⌘1 · ⌥Space · bell 클릭의 목적지: 대화를 연다. `requestID`가 목록에 있으면 그 요청, 아니면 서버 순서 첫 요청 (없으면 빈 상태).
    /// 이미 열려 있어도 접지 않고 그 요청으로 간다 (OA U3-43). 열기는 어떤 답도 아니다
    func openTaskforce(requestID: String? = nil) {
        guard taskforceEnabled else { return }
        let queue = taskforceQueue
        // 읽기의 주인: 패널이 닫혀 있었으면 컨트롤러의 "패널 열기" 읽기가 읽는다. 패널이 이미 열려 있었으면(이 대화든 Projects든) 컨트롤러는 읽지 않으니 여기서 읽는다 (OA U3 검토 1)
        let panelWasOpen = panelOpen
        taskforceShownID = requestID.flatMap { queue.contains($0) ? $0 : nil } ?? queue.first?.id
        taskforcePreviousIDs = queue.ids
        openPanel(.review)
        if panelWasOpen { refreshTaskforce() }
    }

    /// 단계 점 · ← →가 가는 곳 (id로). 단계를 옮기는 것은 답이 아니다
    func showTaskforceRequest(_ id: String) {
        guard taskforceEnabled, view == .review, panelOpen, taskforceQueue.contains(id) else { return }
        taskforceShownID = id
    }

    /// ← →: 목록에서 한 칸 (끝에서 돌지 않는다)
    func stepTaskforce(_ offset: Int) {
        guard taskforceEnabled, view == .review, panelOpen, let id = taskforceShownID, let next = taskforceQueue.neighbor(of: id, offset: offset) else { return }
        taskforceShownID = next
    }

    /// v2 Review를 다시 읽는다 (읽기만: 정해진 주기 읽기는 없다 — 이 GET은 제안 노출 표시를 한다, U3-21). 마지막에 시작한 읽기만 반영된다
    func refreshTaskforce() {
        guard let store = taskforceStore else { return }
        Task { [weak self] in
            await store.refresh()
            self?.taskforceChanged()
        }
    }

    /// 읽은 것이 바뀐 뒤 보던 요청을 맞춘다: 보던 id가 그대로 있으면 순서가 바뀌어도 그 요청, 빠졌으면 그 뒤를 이은 요청, 없으면 서버 순서 첫 요청.
    /// 대화가 그 요약을 처음 그리게 됐으면 첫 정상 표시 기준점을 받는다
    func taskforceChanged() {
        guard taskforceEnabled else { return }
        let queue = taskforceQueue
        let next = queue.resolving(taskforceShownID, previous: taskforcePreviousIDs)
        if taskforceShownID != next { taskforceShownID = next }
        taskforcePreviousIDs = queue.ids
        if taskforceConversationOpen { considerSummaryBaseline() }
    }

    /// 새 `/now`를 받았다: 확인 요청 id가 바뀌었으면 v2를 다시 읽는다 (U3-20)
    fileprivate func workChangedForTaskforce(previous: EdgeWorkSnapshot) {
        guard taskforceEnabled else { return }
        let ids = Set(work.review.map(\.id))
        let changed = ids != taskforceConfirmationIDs
        taskforceConfirmationIDs = ids
        if changed, signedInForTaskforce { refreshTaskforce() } else { taskforceChanged() }
    }

    /// 세션이 바뀌었다: task 상태가 바뀐 세션이 있으면 v2를 다시 읽는다 (결과 · 충돌이 task 상태를 따른다, U3-20)
    fileprivate func sessionsChangedForTaskforce() {
        guard taskforceEnabled, let issues, issues.sessions.hasRead else { return }
        var signature: [UUID: String] = [:]
        for item in issues.sessions.items {
            signature[item.id] = "\(item.lastTaskState.map { String(describing: $0) } ?? "-")|\(item.cancelRequested)|\(item.turnSeq)|\(item.status)"
        }
        let changed = !taskforceSessionSignature.isEmpty && signature != taskforceSessionSignature
        taskforceSessionSignature = signature
        if changed, signedInForTaskforce { refreshTaskforce() } else { taskforceChanged() }
    }

    /// 로그인한 계정이 있어야 읽는다 (로그아웃에서는 읽지 않는다)
    private var signedInForTaskforce: Bool { account != nil }

    /// 깨어났다 (잠자기에서): v2를 한 번 읽는다 (U3-20)
    func taskforceWoke() {
        guard taskforceEnabled, signedInForTaskforce else { return }
        refreshTaskforce()
    }

    // MARK: 요청에 대한 동작

    /// 경로 충돌에 답을 고른다 (클릭 · 1/2 키): 보이는 충돌 요청에만, 오프라인이 아닐 때만. 2초 보류 뒤 보낸다 (`TaskforceRequestStore`). 처리했으면 true
    @discardableResult
    func answerConflict(_ keep: TaskforceConflictKeep, for requestID: String) -> Bool {
        guard let rendered = taskforceStore?.renderedConflict(for: requestID) else { return false }
        return answerConflict(keep, for: requestID, rendered: rendered)
    }

    /// 카드의 클릭: 카드가 그려질 때의 version · 두 세션(`rendered`)을 함께 낸다. 그 뒤 충돌이 바뀌었으면 저장소가 거절하고 새 카드가 말한다 (OA U3 검토 1)
    @discardableResult
    func answerConflict(_ keep: TaskforceConflictKeep, for requestID: String, rendered: TaskforceRenderedConflict) -> Bool {
        guard taskforceConversationOpen, taskforceScreen.canAnswer, let request = shownTaskforceRequest, request.id == requestID, request.kind == .pathConflict else { return false }
        return taskforceStore?.choose(keep, for: requestID, rendered: rendered) ?? false
    }

    /// Taskforce 대화의 1 · 2 키 (OA U3-42): 보이는 요청이 확인 요청이면 Confirm · Dismiss(v1 경로), 경로 충돌이면 Keep 둘(2초 보류), 결과는 답이 없어 키가 지나간다.
    /// 읽는 중 · 오프라인 · 요청이 없는 화면도 지나간다. 반복 키는 먹기만 한다 (한 번의 선택은 한 번의 요청). 키를 먹었으면 true
    func taskforceAnswerKey(_ answer: ReviewAnswer, repeated: Bool) -> Bool {
        guard taskforceConversationOpen, taskforceScreen.canAnswer, let request = shownTaskforceRequest else { return false }
        switch request.kind {
        case .confirm:
            if !repeated, let id = shownReview?.id { self.answer(answer, for: id) }
            return true
        case .pathConflict:
            if !repeated, let keep = TaskforceConflictKeep(key: answer.key) { answerConflict(keep, for: request.id) }
            return true
        case .resultReady:
            return false
        }
    }

    /// Try again (오프라인 · 읽기 실패 · 일부만): 컨트롤러의 `load(.retry)`가 v2도 한 번 읽는다. 이 GET은 제안 노출 표시를 하므로 따로 한 번 더 읽지 않는다
    func taskforceTryAgain() {
        onRetry()
    }

    /// Answer sent의 Undo (보류 안에서만)
    func undoConflict(_ requestID: String) {
        taskforceStore?.undo(requestID)
    }

    /// Result ready의 세션 줄 · 충돌 카드의 세션 줄: 그 세션이 일하는 이슈의 상세와 세션 패널 (OA U3-26). 이슈를 모르는 세션이면 아무 일도 없다
    func openTaskforceSession(_ sessionID: UUID) {
        guard let issues, let item = issues.sessions.item(id: sessionID), let issue = item.currentIssueID ?? item.issueIDs.first else { return }
        openIssueFromOutside(issue)
        openSession(sessionID)
    }

    // MARK: 대화 안 요약 · 빈 상태

    /// 대화 끝의 요약 (변화만): 줄을 누를 수 있나는 지금 목록에 그 작업이 있는가
    var taskforceSummaryContent: ReturnSummaryContent? {
        guard let summary else { return nil }
        let known = Set(workItems.map(\.id))
        return summary.changesOnlyContent(canOpen: { known.contains($0) })
    }

    /// 빈 대화의 Next 줄: Now의 첫 항목 (끝나지 않은 이슈 중 맨 앞). Now가 비면 nil — 대화는 Projects 버튼을 보인다 (OA U3-29)
    var taskforceNext: IssueRowContent? {
        IssueListRules.nextRow(items: workItems, sessions: issues?.sessions.items ?? [], today: DueDateFormat.today())
    }

    /// 요청 카드가 말할 충돌의 두 세션과 경로 (읽은 것만: 하나라도 없으면 nil)
    func taskforceConflictSides(_ request: TaskforceRequest) -> (path: String, first: AgentSessionItem, second: AgentSessionItem)? {
        guard request.kind == .pathConflict, let conflict = request.conflict, let detail = taskforceStore?.conflicts[conflict.leaseID],
              let holder = detail.holderSessionID, let later = detail.laterSessionID,
              let first = issues?.sessions.item(id: holder), let second = issues?.sessions.item(id: later) else { return nil }
        return (detail.relPath, first, second)
    }
}

#endif
