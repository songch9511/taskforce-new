#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import TaskforceKit

/// ⌥Space 런처의 상태와 키보드. 무엇을 보여 줄지(입력 모드 · 거르기 · 묶기 · 접기 · 범위)는 TaskforceKit의 순수 함수(`LauncherContent`)가 정하고,
/// 여기서는 선택 · 화면 전환 · 서버 호출만 한다. 화면(760×480 셸, Figma 156:6 M1 · M13 · M15 · M19 · M20 · M21)은 `LauncherRootView`.
@MainActor
@Observable
final class LauncherModel {
    /// 할 일 행에서 ⌘K로 여는 동작 패널의 대상
    struct Target: Equatable {
        let action: ActionSummary
        let group: TaskGroup
    }

    enum Screen: Equatable {
        case list
        /// ⌘K 동작 패널
        case actions(Target)
        /// Tab/→ 펼침 (Review 행은 ↩ · 클릭도): Sources 묶음
        case detail(Target)
        case editDue(Target)
        /// 할 일 행이 아닌 줄(빈 화면 · 안내 · 저장본 등)에서 ⌘K: 명령 (Send clipboard as source · Report missing action · Connections · Settings · Quit)
        case commands
        /// 직접 추가: 기한 고르기 → 원문 고르기(없어도 됨) → 줄 고르기. 원문 고르기에서 돌아와도 고른 기한이 남는다.
        case addDue(Draft)
        case working(String)
        /// 답 + 근거 줄 (근거 줄은 한 번만 만든다)
        case answer(question: String, response: AskResponse, lines: [EvidenceLine])
        /// 원문 고르기 → 줄 고르기 (빠진 할 일 신고 · 직접 추가의 근거)
        case pickSource(SourcePurpose)
        case pickLines(SourceRecord, SourcePurpose)
        /// 동작 완료 (잠시 뒤 닫힌다)
        case done(String)
        case notice(String)
        /// 외부 AI 처리 동의가 먼저 필요함
        case consentNeeded
        /// Run with AI (Figma M8, U2 Mac): Goal을 적고 ⌘↩로 시작. 목록은 흐리게 두고 상세 칸이 폼이 된다
        case runWithAI(Target)
        /// 초안 보기 (Figma 없음, U2 Mac 계획 열린 질문 5). 목록에 없는 할 일(오늘 전에 끝냄)의 초안이면 대상이 nil
        case draft(Target?, Artifact)
    }

    enum ActionEntry: Hashable {
        /// 진행 상태로 옮기기 (To Do · In Progress · Done). 왼쪽은 상태 표시
        case state(WorkState)
        case confirm, dismiss, handoff, openSource, editDue, delete
        /// ⌘K `Taskforce on this task` 묶음 (Figma M7 일부)
        case runWithAI, stopTaskforce

        var title: String {
            switch self {
            case .state(let state): state.title
            case .confirm: "Confirm"
            case .dismiss: "Dismiss"
            case .handoff: "Hand off to AI"
            case .openSource: "Open source"
            case .editDue: "Edit due"
            case .delete: "Delete"
            case .runWithAI: "Run with AI…"
            case .stopTaskforce: "Stop Taskforce"
            }
        }

        /// 상태 줄은 nil (상태 표시를 그린다)
        var symbolName: String? {
            switch self {
            case .state: nil
            case .confirm: "checkmark"
            case .dismiss: "xmark"
            case .handoff: "paperplane"
            case .openSource: "arrow.up.right.square"
            case .editDue: "calendar"
            case .delete: "trash"
            case .runWithAI: "play.circle"
            case .stopTaskforce: "stop.circle"
            }
        }

        /// 줄 오른쪽에 보이는 단축키 (Review Confirm ⌘↩ · Dismiss ⌘⌫, 할 일 Delete ⌘⌫, Run with AI ⌘R · Stop Taskforce ⌘.)
        var shortcut: String? {
            switch self {
            case .confirm: "⌘↩"
            case .dismiss, .delete: "⌘⌫"
            case .runWithAI: "⌘R"
            case .stopTaskforce: "⌘."
            default: nil
            }
        }
    }

    /// ⌘K 패널의 묶음 ("Status" · "Actions"). Review는 제목 없이 한 묶음
    struct ActionGroup: Equatable {
        let title: String?
        let entries: [ActionEntry]
    }

    typealias DueChoice = LauncherDue.Choice

    /// 원문 · 줄 고르기를 연 흐름
    enum SourcePurpose: Equatable {
        case reportMissing
        /// 직접 추가 (제목 · 기한을 고른 뒤)
        case add(Draft)
    }

    /// 직접 추가할 할 일
    struct Draft: Equatable {
        let title: String
        let due: LocalDate?
    }

    /// 액션 바 Return 동작 · 보조 동작 (이름 + 단축키, `ActionBar`)
    struct BarAction: Equatable {
        let title: String
        let keys: String
    }

    /// 본문 카드에 무엇을 보이나 (Figma M1 · M20 · M21 · 불러오는 중)
    enum Body: Equatable {
        /// 설정 오류 한 줄
        case message(String)
        /// 로그인 상태 · 첫 목록을 기다리는 중 (보일 저장본도 없음)
        case loading
        /// M20: 오프라인 + 이 Mac에 저장본 없음
        case offlineEmpty
        /// 새로고침 실패 + 저장본 없음
        case failedEmpty
        /// 첫 동기화 중이고 할 일이 아직 없음
        case syncing
        /// M21: 할 일 없음
        case empty
        /// 목록 | 상세 (M1)
        case list
        /// 한 열: 로그인 줄 · ⌘K 패널 · 기한 · 원문 고르기 등
        case single
    }

    var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    var selection = 0
    private(set) var screen: Screen = .list
    /// 바뀌면 입력창에 포커스를 준다
    private(set) var focusRequest = 0
    private(set) var recentSources: [SourceSummary] = []
    private(set) var sourceText: SourceText?
    var lineSelection = LineSelection()
    var lineCursor = 0
    var pickedDate = Date()
    let configurationError: String?

    let session: SessionStore?
    let services: AppServices?
    let now: NowStore?
    let account: AccountStore?
    let changes = ActionChangeFeed()
    /// 이 기기의 저장본 (계정별 폴더). 없으면 저장본 없이 둔다 (테스트 · 설정 오류)
    let saved: SavedNowStore?
    /// 실행 (U2): 쓸 수 있는지 · run · 초안 · 폴링. 화면 규칙 밖의 상태와 서버 호출은 여기에 둔다
    let runs: RunStore?
    /// Run with AI의 Goal: 할 일마다 런처를 닫을 때까지 남는다 (사용자 글: 메모리에만)
    private var goals: [UUID: String] = [:]
    /// Run with AI의 Use 칩 (읽는 중이면 nil)
    private(set) var draftSources: [DraftSource]?
    /// 상세에서 Tab · →로 갈래 버튼(`View Draft`)에 옮긴 할 일 (`laneFocusTarget`)
    private var laneFocus: UUID?

    /// 범위 (Figma M13 `All Tasks ⌄`, ⌘P). 런처를 열 때 · 계정이 바뀌면 All Tasks.
    /// 고른 범위가 메뉴에서 사라지면(실행을 쓸 수 없게 됨 · 저장본) All Tasks로 본다
    var scope: TaskScope { scopeChoices.contains(chosenScope) ? chosenScope : .allTasks }
    private var chosenScope: TaskScope = .allTasks
    /// 섹션 펼침 (Show N More · Done Today). 런처를 열 때 · 계정이 바뀌면 처음 모양
    private(set) var caps = SectionCaps()
    /// 범위 메뉴가 열려 있으면 고른 줄 (`scopeChoices`의 자리)
    private(set) var scopeMenuSelection: Int?
    /// 바뀜 점을 지우고 `seen`을 보낼 때 (`SeenTracker`)
    private(set) var seen = SeenTracker()
    /// 앱을 연 뒤 지금 계정이 아닌 저장본을 한 번 정리했는지
    private var prunedSaved = false
    private var connectivityTask: Task<Void, Never>?

    /// 패널 컨트롤러가 채운다
    var close: () -> Void = {}
    var presentationAnchor: () -> NSWindow? = { nil }
    /// Google 로그인 창을 띄운 동안은 포커스를 잃어도 닫지 않는다
    private(set) var suspendsAutoClose = false

    /// 취소해도 되는 읽기 (물어보기 · 원문 읽기). 쓰기는 창을 닫아도 끝까지 보낸다.
    private var work: Task<Void, Never>?
    /// 동작 완료 뒤 닫기
    private var closeTimer: Task<Void, Never>?
    /// 쓰기마다 오른다: 끝난 쓰기가 그사이 바뀐 화면을 덮지 않게
    private var writeGeneration = 0
    /// 보내는 중인 직접 추가 · 빠진 할 일 신고의 쓰기 번호. 한 흐름에 한 번만 보낸다 (`isSubmitting`).
    private var submission: Int?
    /// 목록이 바뀌어도 같은 행을 가리키게 (Realtime · 다시 불러오기)
    private var selectedID: String?
    /// 목록에서 펼침 · ⌘K 패널을 연 할 일과 그때의 자리. 목록으로 돌아오면 그 행을 고른다 (`returnToList`)
    private var viewed: (id: UUID, row: Int)?
    /// 고른 줄이 없는 상태 (돌아왔는데 본 할 일이 사라졌고 가까운 할 일 행도 없음): ↩ · ⌘↩ · ⌘⌫가 아무 행에도 닿지 않는다
    private static let noRow = -1
    /// 방금 옮기거나 지운 할 일: 잠시 ⌘Z로 그 전 상태로 되돌린다 (아래 "Undo ⌘Z")
    private(set) var undoOffer = UndoOffer()
    private var undoTimer: Task<Void, Never>?
    /// ⌘⌫ 반복 입력 · 안내를 닫은 직후의 ⌘⌫를 무시한다 (다음 줄의 Review · 할 일을 지우지 않게)
    private var deleteGuard = LauncherDeleteGuard()
    private var lastUserID: UUID?
    /// 런처가 떠 있는지 (연결 동기화를 다시 읽는 것은 떠 있는 동안만)
    private(set) var isShown = false
    /// 누른 알림의 할 일: 목록에 보이면 그 행을 고른다 (`focus(actionID:)`)
    private var pendingFocus: UUID?
    /// 로그인 전(앱을 링크로 막 열어 세션을 읽는 중 · 로그아웃)에 받은 초안 링크: 처음 로그인하면 연다 (`pendingFocus`처럼)
    private var pendingDraft: UUID?
    /// 최근 원문을 다 읽었는지 (빈 목록과 읽는 중을 나눈다)
    private(set) var sourcesLoaded = false

    /// `saved`: 이 기기의 저장본 (앱은 App Group 위치, 테스트는 임시 폴더나 nil).
    /// `connectivity`: 연결 경로 (앱은 `Connectivity.updates()`, 기본은 바로 끝나는 스트림이라 연결 감시 없음).
    /// `runs`: 실행 상태 (앱은 설정 창과 같은 `AppRuntime.runs`, 없으면 이 런처만의 것)
    init(
        session: SessionStore, services: AppServices, account: AccountStore, saved: SavedNowStore? = nil, runs shared: RunStore? = nil,
        connectivity: AsyncStream<Bool> = AsyncStream { $0.finish() }
    ) {
        self.session = session
        self.services = services
        self.account = account
        self.saved = saved
        let now = NowStore(services: services, session: session, saved: saved)
        let runs = shared ?? RunStore(services: services, session: session)
        var sample = false
        #if DEBUG
        if SampleData.isEnabled {
            now.useSampleData()
            runs.useSampleData()
            account.useSampleData(connections: SampleData.connections, policyNotice: SampleData.policyNotice)
            sample = true
        }
        #endif
        self.now = now
        self.runs = runs
        configurationError = nil
        // 지켜보던 run이 끝나면 `/now`를 다시 받는다 (바뀜 점은 초안 receipt로 서버가 켠다, 앱이 만들지 않는다)
        runs.onRunsFinished = { [weak now] in Task { await now?.load() } }
        // 계정이 떠나면 (로그아웃 · 만료 · 계정 삭제 · 전환) 그 자리에서 이 기기의 저장본(할 일 제목 · 기한 · 상태)을 모두 지운다:
        // 다른 계정의 사본이 남지 않게. 화면 정리(아래)보다 먼저: 전환한 계정이 지워질 사본을 읽어 보이지 않게
        if let saved {
            session.onSignedOut { _ in try? saved.removeAll() }
        }
        // 상태가 바뀐 그 자리에서 화면 · 목록 · 진행 중 작업을 지운다:
        // 런처가 떠 있어도 전 계정의 목록이 한 번도 다음 상태와 함께 그려지지 않게. 로그인 쪽은 `MacAppDelegate`가 따라간다
        session.onSignedOut { [weak self] _ in self?.sessionChanged() }
        // 새 `/now`가 오면 서버의 바뀜이 진실이다 (보낸 seen 기록을 비운다)
        now.onLoaded = { [weak self] in self?.nowRefreshed() }
        guard !sample else { return }
        // 연결이 끊기면 오프라인 화면, 돌아오면 목록을 다시 불러온다 (M20 "연결이 돌아오면 자동으로")
        // 모델이 사라지면 다음 신호에서 끝난다 (스트림을 놓으면 감시도 멈춘다)
        connectivityTask = Task { [weak self] in
            for await online in connectivity {
                guard let self else { return }
                self.connectivityChanged(online)
            }
        }
    }

    init(configurationError: String) {
        session = nil
        services = nil
        now = nil
        account = nil
        saved = nil
        runs = nil
        self.configurationError = configurationError
    }

    var isSignedIn: Bool {
        #if DEBUG
        if now?.sampleMode == true { return true }
        #endif
        if case .signedIn = session?.state { return true }
        return false
    }

    var signedInUserID: UUID? {
        if case .signedIn(let userID, _) = session?.state { userID } else { nil }
    }

    var inputMode: LauncherInput.Mode { LauncherInput.mode(for: text) }

    var sections: [LauncherSection] {
        guard configurationError == nil, isSignedIn || session?.state != .loading else { return [] }
        let layout = listLayout
        // 이번 실행에서 `/now`를 받기 전이면 이 기기의 저장본 (읽기만)
        if isSignedIn, let saved = savedList {
            return LauncherContent.savedSections(saved, for: inputMode, layout: layout, now: Date())
        }
        // 먼저 보여 주는 완료 · 착수 · 다시 열기를 얹은 목록
        let board = now?.board
        return LauncherContent.sections(
            for: inputMode, now: board?.now, doneToday: board?.doneToday ?? [], signedIn: isSignedIn,
            needsConsent: account?.shouldPromptConsent ?? false, policyNotice: account?.policyNotice,
            googleSignIn: GoogleSignInFlow.isAvailable, layout: layout
        )
    }

    var items: [LauncherItem] { sections.flatMap(\.items) }

    /// 목록 모양: 접기 기준은 서버 값(`section_limits`), 범위 · 바뀜 · 실패 원문 줄
    private var listLayout: LauncherContent.Layout {
        var caps = self.caps
        caps.limits = now?.response?.sectionLimits ?? .standard
        return LauncherContent.Layout(
            caps: caps, scope: scope, changed: changedIDs, working: workingIDs, failedSources: now?.response?.failedSources ?? .empty
        )
    }

    /// 끝나지 않은 run이 있는 할 일 (범위 Taskforce Working)
    private var workingIDs: Set<UUID> { runs?.workingActionIDs ?? [] }

    /// 이번 실행에서 `/now`를 아직 받지 못했을 때 보이는 이 기기의 저장본 (오프라인 · 새로고침 실패 · 처음 불러오는 중)
    var savedList: SavedNow? {
        guard now?.response == nil else { return nil }
        return now?.savedCopy
    }

    /// 서버가 바뀜이라 한 할 일 (Review · In Progress · To Do)
    var changedIDs: Set<UUID> { now?.board.now?.changedIDs ?? [] }

    /// 바뀜 점을 보일지 (seen을 보낸 할 일은 다음 `/now`까지 지운다)
    func showsDot(_ id: UUID) -> Bool { seen.showsDot(id, changed: changedIDs) }

    /// 연결 · 불러오기 상태 (액션 바 왼쪽, M15 · M19 · M20)
    var refreshState: RefreshState { now?.refreshState ?? .live }

    /// 보이는 목록이 저장본(또는 이번 실행에서 받은 마지막 목록)이라 검색줄이 `Search saved tasks`인지 (M15 · M19)
    var showsSavedTasks: Bool {
        guard isSignedIn else { return false }
        return refreshState.showsSavedTasks || savedList != nil
    }

    /// 본문 카드 (Figma M1 목록 | 상세 · M20 · M21 · 불러오는 중)
    var bodyState: Body {
        if let configurationError { return .message(configurationError) }
        switch screen {
        case .list: break
        // Run with AI · 초안: 목록은 흐리게 두고 상세 칸이 바뀐다 (Figma M8)
        case .detail, .runWithAI, .draft: return .list
        default: return .single
        }
        guard isSignedIn else { return session?.state == .loading ? .loading : .single }
        let items = items
        if now?.response == nil, savedList == nil, inputMode == .empty || items.isEmpty {
            // 이번 실행에서 받은 목록도 저장본도 없다
            switch refreshState {
            case .offlineEmpty: return .offlineEmpty
            case .refreshFailed: return .failedEmpty
            default: return .loading
            }
        }
        guard items.isEmpty else { return .list }
        if showsSyncing { return .syncing }
        return inputMode == .empty ? .empty : .list
    }

    /// 할 일이 하나도 없는데 연결이 동기화 중이면 "Syncing…" (빈 입력창일 때만): 목록이 비면 가운데, 안내 줄이 있으면 목록 맨 위 한 줄
    var showsSyncing: Bool {
        guard isSignedIn, inputMode == .empty, account?.anySyncing == true else { return false }
        return !items.contains { $0.group != nil }
    }

    var selectedItem: LauncherItem? {
        let items = items
        return items.indices.contains(selection) ? items[selection] : nil
    }

    var filteredSources: [SourceSummary] {
        // 직접 추가 중에는 입력창에 제목이 있어서 거르지 않는다
        guard case .pickSource(.reportMissing) = screen else { return recentSources }
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recentSources }
        return recentSources.filter { TaskFilter.matches(text: $0.title ?? "", query: query) }
    }

    var dueChoices: [DueChoice] {
        let today = DueDateFormat.today()
        if case .addDue(let draft) = screen { return LauncherDue.choices(today: today, adding: true, keeping: draft.due) }
        return LauncherDue.choices(today: today, adding: false)
    }

    /// 직접 추가의 원문 고르기는 맨 위에 "No source" 한 줄이 있다
    var sourceRowOffset: Int {
        if case .pickSource(.add) = screen { 1 } else { 0 }
    }

    /// ⌘K로 동작 패널을 열 수 있는지 (아래 "Actions ⌘K"). 할 일 행이 아니면 명령 패널 (로그인한 동안)
    var canOpenActions: Bool {
        switch screen {
        case .list: selectedItem?.action != nil || (isSignedIn && configurationError == nil)
        case .detail, .runWithAI, .draft(.some, _): true
        default: false
        }
    }

    /// 상세 칸에 보일 할 일: 목록에서 고른 할 일 행(Hand off 행은 그 할 일), 상세로 포커스를 옮겼으면 그 할 일(지금 구역)
    var detailTarget: Target? {
        switch screen {
        case .list:
            guard let item = selectedItem, item.group != nil else { return nil }
            return target(for: item)
        case .detail(let target):
            return focusedTarget ?? target
        case .runWithAI(let target), .draft(let target?, _):
            return target
        default:
            return nil
        }
    }

    /// 상세 칸에 보일 저장본 한 줄 (저장본 목록에서 고른 행)
    var detailSavedRow: SavedNow.Row? {
        guard screen == .list, case .saved(let row)? = selectedItem else { return nil }
        return row
    }

    // MARK: 액션 바

    /// Return 동작 (회색 알약): 할 일 행은 원문 열기(`Open in Notion`, 근거를 읽은 뒤), Review 행은 `Show Review`,
    /// 상세로 포커스한 Review는 `Confirm ⌘↩`, 범위 메뉴가 열려 있으면 `Show <범위>`. 없으면 nil
    var primaryAction: BarAction? {
        if let index = scopeMenuSelection, scopeChoices.indices.contains(index) {
            return BarAction(title: "Show \(scopeChoices[index].title)", keys: "↩")
        }
        switch screen {
        case .list:
            guard let item = selectedItem, let target = target(for: item), item.group != nil else { return nil }
            if target.group == .review { return BarAction(title: "Show Review", keys: "↩") }
            guard let link = Self.sourceLink(now?.evidence[target.action.id]) else { return nil }
            let opensDraft = link.externalURL.flatMap(ArtifactLink.parse) != nil
            return BarAction(title: opensDraft ? "View Draft" : link.service.openTitle, keys: "↩")
        case .detail:
            if laneFocusTarget != nil { return BarAction(title: "View Draft", keys: "↩") }
            return canConfirmReview ? BarAction(title: "Confirm", keys: "⌘↩") : nil
        case .runWithAI:
            return BarAction(title: "Start", keys: "⌘↩")
        case .draft(_, let artifact):
            return artifact.isPurged ? nil : BarAction(title: "Copy", keys: "⌘C")
        case .pickLines(_, let purpose):
            guard selectedQuote != nil else { return nil }
            return BarAction(title: purpose == .reportMissing ? "Report" : "Add", keys: "⌘↩")
        default:
            return nil
        }
    }

    /// 보조 동작: 방금 옮긴 · 지운 할 일 `Undo ⌘Z`, 상세의 Review `Dismiss ⌘⌫`, 고른 안내 줄 `Dismiss ⌘⌫`, 새로고침 실패 `Try Again ⌘R` (M19)
    var secondaryAction: BarAction? {
        guard scopeMenuSelection == nil else { return nil }
        switch screen {
        case .list, .detail:
            if canUndo { return BarAction(title: "Undo", keys: "⌘Z") }
            if canDismissNotice || (canDismissReview && screen != .list) { return BarAction(title: "Dismiss", keys: "⌘⌫") }
            if case .refreshFailed = refreshState, isSignedIn { return BarAction(title: "Try Again", keys: "⌘R") }
            return nil
        default:
            return nil
        }
    }

    /// 액션 바 왼쪽 문장: 오프라인 · 새로고침 실패 (M15 · M19 · M20). 401이면 다시 시도보다 로그아웃 · 로그인 안내. 온라인이면 nil (`Tasks`)
    var statusText: String? {
        guard isSignedIn else { return nil }
        if case .refreshFailed = refreshState, now?.authFailed == true, let error = now?.loadError { return error }
        return refreshState.statusText()
    }

    /// 액션 바 버튼을 누름 (같은 키를 누른 것과 같다)
    func performPrimary() {
        if let index = scopeMenuSelection, scopeChoices.indices.contains(index) {
            chooseScope(scopeChoices[index])
            return
        }
        switch screen {
        case .list:
            guard let item = selectedItem else { return }
            if item.group == .review { expand() } else if let target = target(for: item) { openSourceOrActions(target) }
        case .detail: if laneFocusTarget != nil { openFocusedDraft() } else { confirmReview() }
        case .pickLines: submitLines()
        case .runWithAI: startRun()
        case .draft: copyDraft()
        default: break
        }
    }

    func performSecondary() {
        switch secondaryAction?.keys {
        case "⌘Z": undo()
        case "⌘R": retry()
        case "⌘⌫":
            if canDismissNotice {
                account?.acknowledgePolicyNotice()
            } else if let target = focusedTarget, target.group == .review {
                perform(.dismiss, on: target)
            }
        default: break
        }
    }

    // MARK: 범위 (M13)

    /// 범위 메뉴의 줄. 서버가 바뀜을 모르면(예전 서버) 바뀜 범위를 숨긴다. Taskforce Working은 실행을 쓸 수 있을 때만 (credits 200)
    var scopeChoices: [TaskScope] {
        TaskScope.menu(tracksChanges: now?.response?.tracksChanges ?? false, showsTaskforce: runs?.isAvailable ?? false)
    }

    /// 범위의 개수 (All Tasks = Review + In Progress + To Do). 저장본이면 저장본으로 센다 (Taskforce Working은 0)
    func count(for scope: TaskScope) -> Int {
        if let saved = savedList { return scope.count(in: saved, now: Date()) }
        guard let sections = now?.sections else { return 0 }
        return scope.count(in: sections, changed: changedIDs, working: workingIDs)
    }

    /// 범위 메뉴를 열 수 있는지 (로그인한 목록에서)
    var canChooseScope: Bool { screen == .list && isSignedIn && configurationError == nil }

    /// ⌘P · `All Tasks ⌄`: 범위 메뉴 열고 닫기 (열면 지금 범위를 고른 채)
    func toggleScopeMenu() {
        if scopeMenuSelection != nil {
            scopeMenuSelection = nil
        } else if canChooseScope {
            scopeMenuSelection = scopeChoices.firstIndex(of: scope) ?? 0
        }
    }

    func closeScopeMenu() {
        scopeMenuSelection = nil
    }

    func selectScopeMenuRow(_ index: Int) {
        guard scopeMenuSelection != nil, scopeChoices.indices.contains(index) else { return }
        scopeMenuSelection = index
    }

    /// 범위를 고름: 고르던 행이 새 목록에 있으면 그 행, 없으면 같은 자리 (`reselect`)
    func chooseScope(_ choice: TaskScope) {
        scopeMenuSelection = nil
        guard choice != scope else { return }
        chosenScope = choice
        reconcileSelection()
    }

    // MARK: 바뀜 점 · seen

    /// seen의 대상: 목록에서 고른 할 일 행, 상세 · ⌘K 패널 · 기한 고치기에서 보는 할 일. 런처가 숨으면 nil (떠남)
    var seenSubject: UUID? {
        guard isShown else { return nil }
        switch screen {
        case .list:
            guard let item = selectedItem, item.group != nil else { return nil }
            return item.action?.id
        case .detail(let target), .actions(let target), .editDue(let target), .runWithAI(let target), .draft(let target?, _):
            return target.action.id
        default:
            return nil
        }
    }

    /// 실행 상태를 지켜볼 할 일 (`RunStore.watch`): 런처가 떠 있는 동안 상세 칸 · Run with AI · 초안 · ⌘K 패널의 할 일
    var runSubject: UUID? {
        guard isShown else { return nil }
        if case .actions(let target) = screen { return target.action.id }
        return detailTarget?.action.id
    }

    /// 고른 할 일이 바뀌었을 때 (화면이 `seenSubject`를 따라 부른다): 떠난 바뀐 행이 있으면 `seen`을 한 번 보낸다.
    /// 점은 바로 지우고, 실패해도 다시 보내지 않는다 (다음 `/now`가 진실)
    func syncSeen() {
        guard let leaving = seen.select(seenSubject, changed: changedIDs), let services else { return }
        #if DEBUG
        if now?.sampleMode == true { return }
        #endif
        Task { try? await services.api.markSeen(leaving) }
    }

    /// 새 `/now`를 받음: 서버의 바뀜이 진실 (지금 고른 행이 이제 바뀜이면 떠날 때 보낸다)
    /// 고르던 행을 먼저 다시 맞춘다(`reconcileSelection`): 위에 행이 들고 나도 같은 자리의 다른 행을 넘기지 않게
    private func nowRefreshed() {
        reconcileSelection()
        seen.refreshed(changed: changedIDs, selected: seenSubject)
        // 초안 링크를 목록보다 먼저 읽었으면(앱을 링크로 막 열었을 때) 목록이 오면 그 할 일을 붙인다 (머리 · ⌘K · esc → 상세)
        if case .draft(nil, let artifact) = screen, let found = now?.sections.find(artifact.actionID) {
            screen = .draft(Target(action: found.action, group: found.group), artifact)
        }
        // M8을 연 뒤 그 할 일이 지워졌거나 끝났거나 Review로 갔으면(다른 기기) 목록으로 (Goal은 남는다)
        if case .runWithAI = screen, runTarget == nil { returnToList() }
    }

    // MARK: 연결 · 저장본

    /// 연결 경로가 바뀜: 오프라인에서 돌아오면 목록을 다시 불러온다
    func connectivityChanged(_ online: Bool) {
        guard let now, now.pathChanged(online: online), isSignedIn else { return }
        Task { await now.load() }
    }

    /// ⌘R · `Try Again`: 다시 불러온다
    func retry() {
        guard isSignedIn, let now else { return }
        Task { await now.load() }
    }

    /// 앱을 연 뒤 로그인 상태를 처음 알게 되면 한 번: 지금 계정이 아닌 저장본을 지운다 (앱이 돌지 않는 동안 떠난 계정, 로그아웃이면 모두)
    private func pruneSavedOnce() {
        guard !prunedSaved, let saved, let state = session?.state, state != .loading else { return }
        prunedSaved = true
        try? saved.prune(keeping: signedInUserID)
    }

    /// ⌘K 패널: Review는 Confirm · Dismiss · …, 나머지는 Status(To Do · In Progress · Done, 지금 상태에 체크) + Actions(맨 아래 Delete).
    /// 실행을 쓸 수 있으면 끝에 `Taskforce on this task`(Figma M7): Run with AI…(시작할 수 있을 때) · Stop Taskforce(끝나지 않은 run이 있을 때)
    func actionGroups(for target: Target) -> [ActionGroup] {
        let status = ActionGroup(title: "Status", entries: WorkState.allCases.map(ActionEntry.state))
        let groups: [ActionGroup] = switch target.group {
        case .review: [ActionGroup(title: nil, entries: [.confirm, .dismiss, .handoff, .openSource, .editDue])]
        case .toDo, .inProgress: [status, ActionGroup(title: "Actions", entries: [.handoff, .openSource, .editDue, .delete])]
        case .doneToday: [status, ActionGroup(title: "Actions", entries: [.openSource, .delete])]
        }
        let taskforce = (runAvailability(for: target).isEnabled ? [ActionEntry.runWithAI] : []) + (canStop(target) ? [.stopTaskforce] : [])
        return taskforce.isEmpty ? groups : groups + [ActionGroup(title: "Taskforce on this task", entries: taskforce)]
    }

    /// ↑↓로 고르는 순서 (묶음을 이어서)
    func actionEntries(for target: Target) -> [ActionEntry] {
        actionGroups(for: target).flatMap(\.entries)
    }

    /// ⌘K를 열면 먼저 고르는 줄: 다음 상태 (To Do → In Progress → Done, Done → 끝내기 전 상태).
    /// Review는 Open source: ↩를 이어 눌러도 확정되지 않게 (확정은 ⌘↩ · Confirm 줄로 옮겨서 ↩)
    private func initialActionIndex(for target: Target) -> Int {
        if target.group == .review { return actionEntries(for: target).firstIndex(of: .openSource) ?? 0 }
        guard let current = WorkState(target.group) else { return 0 }
        let next: WorkState = switch current {
        case .toDo: .inProgress
        case .inProgress: .done
        case .done: now?.toggleTarget(target.action.id) ?? .toDo
        }
        return actionEntries(for: target).firstIndex(of: .state(next)) ?? 0
    }

    /// 방금 옮기거나 지운 할 일을 ⌘Z로 되돌릴 수 있는지 (목록에서만)
    var canUndo: Bool { screen == .list && undoOffer.pending != nil }

    /// 고른 Review 행 · 펼친 Review를 ⌘↩로 확정할 수 있는지 (아래 "Confirm ⌘↩")
    var canConfirmReview: Bool {
        switch screen {
        case .list, .detail: focusedTarget?.group == .review
        default: false
        }
    }

    /// 고른 Review 행 · 펼친 Review를 ⌘⌫로 넘길 수 있는지 (아래 "Dismiss ⌘⌫"). 입력이 있으면 ⌘⌫는 입력창의 줄 지우기
    var canDismissReview: Bool {
        guard canConfirmReview, case (.dismiss, _)? = deleteShortcut else { return false }
        return true
    }

    /// 고른 줄이 처리방침 변경 안내라 ⌘⌫로 닫을 수 있는지 (아래 "Dismiss ⌘⌫").
    /// 공백만 입력해도 안내 줄은 보이지만, 그때 ⌘⌫는 입력창의 줄 지우기다
    var canDismissNotice: Bool {
        guard screen == .list, text.isEmpty, case .policyNotice = selectedItem else { return false }
        return true
    }

    /// 지금 화면에서 ↑↓로 고르는 줄 수
    var rowCount: Int {
        switch screen {
        case .list: items.count
        case .actions(let target): actionEntries(for: target).count
        case .commands: LauncherCommand.allCases.count
        case .editDue, .addDue: dueChoices.count
        case .pickSource: sourceRowOffset + filteredSources.count
        case .pickLines: sourceText?.lines.count ?? 0
        default: 0
        }
    }

    // MARK: 열고 닫기

    func prepareForShow() {
        isShown = true
        closeTimer?.cancel()
        clearUndo()
        focusRequest += 1
        // 직접 추가 · 신고를 보내는 중이면 그 진행 화면을 그대로 보여 준다 (목록으로 돌아가 다시 보내면 중복)
        guard !isSubmitting else { return }
        work?.cancel()
        text = ""
        screen = .list
        selection = 0
        selectedID = nil
        viewed = nil
        pendingFocus = nil
        // 열 때마다 처음 모양: All Tasks · 접힌 섹션
        chosenScope = .allTasks
        caps.reset()
        scopeMenuSelection = nil
        guard isSignedIn, let now else { return }
        Task { await now.load() }
        loadRuns()
        // 동의 · 연결 상태 (동의 전인데 연결이 있으면 맨 위에 "Allow AI processing").
        // 연결이 있으면 알림 권한을 한 번 묻는다 (첫 실행 · 연결 전에는 묻지 않는다)
        if let account {
            Task {
                await account.load()
                await PushCenter.shared.requestIfNeeded(hasConnections: account.hasConnections)
            }
            loadPolicyNotice()
        }
    }

    /// 처리방침 변경 안내 (못 읽으면 조용히 넘긴다)
    private func loadPolicyNotice() {
        guard let account, let userID = signedInUserID else { return }
        Task { await account.loadPolicyNotice(userID: userID) }
    }

    func didHide() {
        isShown = false
        closeTimer?.cancel()
        suspendsAutoClose = false
        scopeMenuSelection = nil
        // 런처를 닫으면 Goal을 지우고 run 상태를 그만 읽는다
        goals = [:]
        runs?.watch([])
        // 닫힘도 떠남이다: 보고 있던 바뀐 행의 seen
        syncSeen()
    }

    /// 누른 알림: 그 할 일(Review · 할 일 행)을 고른다. 아직 목록에 없으면 다시 읽은 목록이 오면 고른다
    func focus(actionID: UUID) {
        guard screen == .list else { return }
        pendingFocus = actionID
        reconcileSelection()
    }

    func reportAppOpened() {
        guard let services else { return }
        Task { try? await services.api.appOpened() }
    }

    /// 로그인 상태가 바뀌면 (로그아웃 · 계정 전환) 전 사용자의 목록을 지운다. 토큰 갱신처럼 같은 사용자면 그대로 둔다.
    func sessionChanged() {
        pruneSavedOnce()
        let userID = signedInUserID
        guard userID != lastUserID else { return }
        // 첫 로그인 · 시작 때의 세션(nil → 계정)이면 로그인 전에 받은 알림 대상 · 입력은 둔다
        let accountLeft = lastUserID != nil
        lastUserID = userID
        work?.cancel()
        work = nil
        closeTimer?.cancel()
        now?.reset()
        account?.reset()
        clearUndo()
        recentSources = []
        sourcesLoaded = false
        sourceText = nil
        goals = [:]
        draftSources = nil
        laneFocus = nil
        // 전 사용자의 쓰기 결과는 보여 주지 않는다
        writeGeneration += 1
        if accountLeft {
            submission = nil
            pendingFocus = nil
            pendingDraft = nil
            text = ""
        }
        screen = .list
        selection = 0
        selectedID = nil
        viewed = nil
        chosenScope = .allTasks
        caps.reset()
        scopeMenuSelection = nil
        seen.reset()
        guard isSignedIn, let now else { return }
        // 이번 실행에서 `/now`를 받기 전에는 이 계정의 저장본을 보인다 (오프라인 · 새로고침 실패)
        now.restoreSaved()
        Task { await now.load() }
        loadRuns()
        if let account { Task { await account.load() } }
        loadPolicyNotice()
        if let id = pendingDraft {
            pendingDraft = nil
            openDraft(id: id)
        }
    }

    /// 실행을 쓸 수 있는지(credits) · 끝나지 않은 run (범위 개수 · ⌘K 항목). 쓸 수 없는 계정이면 run은 읽지 않는다
    private func loadRuns() {
        guard let runs else { return }
        Task {
            await runs.loadCredits()
            await runs.refreshActive()
        }
    }

    // MARK: 키보드

    /// 런처 창의 키 입력. 처리했으면 true (입력창으로 보내지 않는다).
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let keyCode = Int(event.keyCode)
        // 기한 고치기의 날짜 칸에 포커스가 있으면 방향키 · Tab은 날짜 칸이 쓰고, ↩는 그 날짜로 저장한다
        if event.window?.firstResponder is NSDatePicker, keyCode != kVK_Escape {
            guard keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter, isChoosingDue else { return false }
            chooseDue(LocalDate(date: pickedDate, timeZone: .current))
            return true
        }
        // 한글 등 입력기가 글자를 조합하는 중이면 ↩ · esc · 방향키 · Tab은 입력기가 쓴다 (조합을 끝내는 ↩가 행을 실행하지 않게)
        if (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true, Self.compositionKeys.contains(keyCode) {
            return false
        }
        if scopeMenuSelection != nil, handleScopeMenuKey(keyCode, command: command) { return true }
        if let handled = handleSubScreenKey(event, keyCode: keyCode, flags: flags) { return handled }
        switch keyCode {
        case kVK_Escape:
            back()
            return true
        case kVK_UpArrow:
            move(-1)
            return true
        case kVK_DownArrow:
            move(1)
            return true
        case kVK_ANSI_P where command:
            // 범위 메뉴 (Raycast 관례)
            guard canChooseScope else { return false }
            toggleScopeMenu()
            return true
        case kVK_ANSI_R where command:
            // 할 일 행 · 상세 · ⌘K 패널에서 Run with AI를 시작할 수 있으면 M8 (M7 `Run with AI… ⌘R`),
            // 그 밖(새로고침 실패 · 오프라인 · 쓸 수 없음 · 할 일 아닌 줄)은 다시 불러오기 (M19 `Try Again ⌘R`, U2 Mac 계획 열린 질문 2)
            if let target = focusedTarget, runAvailability(for: target).isEnabled {
                openRun(target)
                return true
            }
            guard isSignedIn, screen == .list || screen.isDetail else { return false }
            retry()
            return true
        case kVK_ANSI_Period where command:
            // Stop Taskforce: 그 할 일의 끝나지 않은 run 전부 (확인 대화 없음, 다음 단계만 막는다)
            guard let target = focusedTarget, canStop(target) else { return false }
            stopTaskforce(target)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // ⌥↩ · ⇧↩는 입력창에서 줄바꿈
            if flags.contains(.option) || flags.contains(.shift) { return false }
            // 펼침 · 패널의 할 일이 그사이 바뀌었으면(다른 기기에서 확정 등) 실행하지 않고 목록으로
            if leaveIfStale() { return true }
            // 상세에서 갈래 버튼으로 옮겼으면 ↩는 View Draft (⌘↩는 그대로 Review 확정)
            if !command, laneFocusTarget != nil {
                if !event.isARepeat { openFocusedDraft() }
                return true
            }
            // Review는 ↩로 확정하지 않는다: ↩ 근거 펼치기, ⌘↩ Confirm, 반복 입력은 무시 (`LauncherReturn`)
            switch LauncherReturn.effect(at: returnPlace, command: command, isRepeat: event.isARepeat) {
            case .primary: command ? commandReturn() : primary()
            case .showSources: expand()
            case .confirm: confirmReview()
            case .openSource: if let target = focusedTarget { openSourceOrActions(target) }
            case .ignore: break
            }
            return true
        case kVK_Tab:
            if screen.isDetail { focusLane() } else { expand() }
            return true
        case kVK_RightArrow:
            if screen.isDetail, caretAtEnd(in: event.window), laneDrafts(focusedTarget) != nil {
                focusLane()
                return true
            }
            guard screen == .list, caretAtEnd(in: event.window), selectedItem?.action != nil else { return false }
            expand()
            return true
        case kVK_ANSI_K where command:
            openActions()
            return true
        case kVK_ANSI_Z where command && !flags.contains(.shift):
            // 되돌릴 완료가 없으면 입력창의 되돌리기
            guard canUndo else { return false }
            undo()
            return true
        case kVK_Delete where command:
            if leaveIfStale() { return true }
            let dismissesNotice = canDismissNotice
            let shortcut = deleteShortcut
            guard dismissesNotice || shortcut != nil else {
                // 펼침에서는 먹는다: 입력창의 줄 지우기로 목록에 돌아가 다른 행에 닿지 않게
                if case .detail = screen { return true }
                // 목록에서는 입력창의 줄 지우기를 그대로 둔다
                return false
            }
            // 누르고 있어 반복된 ⌘⌫ · 안내를 닫은 직후의 ⌘⌫는 먹고 아무것도 하지 않는다 (`LauncherDeleteGuard`)
            guard deleteGuard.allows(isRepeat: event.isARepeat, at: Date()) else { return true }
            if dismissesNotice {
                account?.acknowledgePolicyNotice()
                deleteGuard.noticeDismissed(at: Date())
            } else if let (entry, target) = shortcut {
                perform(entry, on: target)
            }
            return true
        default:
            return false
        }
    }

    /// 입력기 조합 중이면 입력기에 넘기는 키
    private static let compositionKeys: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape, kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Tab,
    ]

    /// 범위 메뉴가 열려 있을 때: ↑↓ 고르기 · ↩ 고름 · esc · ⌘P 닫기. 다른 키는 메뉴를 닫고 평소처럼 (처리했으면 true)
    private func handleScopeMenuKey(_ keyCode: Int, command: Bool) -> Bool {
        guard let index = scopeMenuSelection else { return false }
        switch keyCode {
        case kVK_UpArrow, kVK_DownArrow:
            scopeMenuSelection = LauncherContent.move(index, by: keyCode == kVK_UpArrow ? -1 : 1, count: scopeChoices.count)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if scopeChoices.indices.contains(index) { chooseScope(scopeChoices[index]) }
            return true
        case kVK_Escape:
            scopeMenuSelection = nil
            return true
        case kVK_ANSI_P where command:
            scopeMenuSelection = nil
            return true
        default:
            scopeMenuSelection = nil
            return false
        }
    }

    /// Run with AI · 초안 화면의 키. 처리하지 않으면 nil (아래 평소 키로)
    /// - M8: esc 상세로 · ⌘↩ Start · ↩ · ⌥↩ · ⇧↩는 Goal 줄바꿈 · 방향키는 입력칸 · ⌘K 할 일 동작
    /// - 초안: esc 상세로 · ⌘C 복사(본문 일부를 골랐으면 그 글) · ⌘. Stop Taskforce · ⌘K 할 일 동작
    private func handleSubScreenKey(_ event: NSEvent, keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool? {
        let command = flags.contains(.command)
        switch screen {
        case .runWithAI:
            switch keyCode {
            case kVK_Escape:
                back()
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if command {
                    if !event.isARepeat { startRun() }
                    return true
                }
                if flags.contains(.option) || flags.contains(.shift) { return false }
                // 입력칸은 ↩를 제출로 받아서 줄바꿈을 직접 넣는다
                (event.window?.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
                return true
            case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
                return false
            case kVK_Tab:
                return true
            case kVK_ANSI_K where command:
                openActions()
                return true
            default:
                return nil
            }
        case .draft(let target, _):
            switch keyCode {
            case kVK_Escape:
                back()
                return true
            case kVK_ANSI_C where command:
                if let editor = event.window?.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
                copyDraft()
                return true
            case kVK_ANSI_Period where command:
                guard let target, canStop(target) else { return false }
                stopTaskforce(target)
                return true
            case kVK_ANSI_K where command:
                openActions()
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_UpArrow, kVK_DownArrow, kVK_Tab:
                return true
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// ⌘⌫: 목록에서 고른 할 일 행 · 펼친 Review · ⌘K 패널의 할 일. Review는 Dismiss, 나머지(In Progress · To Do · Done Today)는 Delete
    private var deleteShortcut: (ActionEntry, Target)? {
        switch screen {
        // 목록에서 입력이 있으면 ⌘⌫는 입력창의 줄 지우기
        case .list: guard text.isEmpty else { return nil }
        // 펼침은 입력이 비었을 때 Review의 Dismiss만 (펼친 할 일의 Delete는 ⌘K 패널에서, 입력이 있으면 먹는다)
        case .detail: guard text.isEmpty else { return nil }
        case .actions: break
        default: return nil
        }
        guard let target = focusedTarget else { return nil }
        if case .detail = screen, target.group != .review { return nil }
        return (target.group.isDeletable ? .delete : .dismiss, target)
    }

    /// 목록에서 고른 할 일 행(Hand off 행은 할 일 행이 아니다) · 펼친 할 일 · ⌘K 패널의 할 일.
    /// 펼침 · 패널은 연 뒤에 바뀌었을 수 있어(다른 기기에서 확정 · 옮김) 지금 목록의 구역으로 본다. 사라졌으면 nil
    private var focusedTarget: Target? {
        switch screen {
        case .list:
            guard let item = selectedItem, item.group != nil else { return nil }
            return target(for: item)
        case .detail(let target), .actions(let target):
            guard let found = now?.sections.find(target.action.id) else { return nil }
            return Target(action: found.action, group: found.group)
        default:
            return nil
        }
    }

    /// ↩ · ⌘↩를 받은 곳 (`LauncherReturn`). 펼침 · 패널은 지금 구역으로
    private var returnPlace: LauncherReturn.Place {
        switch screen {
        case .list: .list(selectedItem)
        case .detail(let target), .actions(let target): .task(focusedTarget?.group ?? target.group)
        default: .other
        }
    }

    /// ⌘↩: 고른 Review 행 · 펼친 Review · ⌘K 패널의 Review를 확정 (패널에서 고른 줄과 상관없이)
    private func confirmReview() {
        guard let target = focusedTarget, target.group == .review else { return }
        perform(.confirm, on: target)
    }

    private func caretAtEnd(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return true }
        let range = editor.selectedRange()
        return range.length == 0 && range.location >= (editor.string as NSString).length
    }

    func move(_ delta: Int) {
        if case .pickLines = screen {
            lineCursor = LauncherContent.move(lineCursor, by: delta, count: rowCount)
            return
        }
        // 상세에 포커스가 있으면 목록으로 돌아와 옮긴다 (목록 | 상세가 함께 보인다)
        if screen.isDetail { returnToList() }
        select(LauncherContent.move(selection, by: delta, count: rowCount))
    }

    /// 행 고르기 (목록이면 그 행의 id도 기억한다)
    func select(_ index: Int) {
        selection = index
        if screen == .list { selectedID = selectedItem?.id }
    }

    /// 목록이 새로 왔을 때: 고르던 행이 아직 있으면 그 행을, 없으면 같은 자리(끝을 넘지 않게)를 가리킨다 (`LauncherContent.reselect`)
    func reconcileSelection() {
        guard screen == .list else { return }
        // 누른 알림의 할 일이 접힌 섹션 · 다른 범위에 있으면 펼쳐서 보인다
        if let pendingFocus, !items.contains(where: { $0.group != nil && $0.action?.id == pendingFocus }),
           let found = now?.sections.find(pendingFocus) {
            chosenScope = .allTasks
            caps.expand(found.group)
        }
        let items = items
        if let pendingFocus, let index = items.firstIndex(where: { $0.group != nil && $0.action?.id == pendingFocus }) {
            self.pendingFocus = nil
            selection = index
            selectedID = items[index].id
        } else if selection == Self.noRow {
            // 고른 줄 없이 둔 상태: 새 목록이 와도 맨 위(다른 Review일 수 있음)를 고르지 않는다
            selectedID = nil
        } else {
            selection = LauncherContent.reselect(selectedID, in: items, at: selection)
            selectedID = items.indices.contains(selection) ? items[selection].id : nil
        }
    }

    /// 목록으로 돌아간다: 펼침 · ⌘K 패널에서 본 할 일이 있으면 그 행, 사라졌으면 가까운 할 일 행(없으면 고른 줄 없음),
    /// 본 할 일이 없으면 맨 위 (`LauncherContent.rowAfterBack`). 고른 줄과 `selectedID`를 늘 함께 맞춘다.
    private func returnToList() {
        screen = .list
        laneFocus = nil
        let items = items
        let row = LauncherContent.rowAfterBack(viewing: viewed?.id, in: items, near: viewed?.row ?? 0)
        viewed = nil
        selection = row ?? Self.noRow
        selectedID = row.flatMap { items.indices.contains($0) ? items[$0].id : nil }
    }

    /// 펼침 · ⌘K 패널의 할 일이 연 뒤에 바뀌었으면(다른 기기에서 확정 · 옮김 · 지움) 아무것도 하지 않고 목록으로 돌아간다.
    /// 바뀐 할 일에 패널의 Dismiss · Delete · Confirm이 닿지 않게. 돌아갔으면 true
    private func leaveIfStale() -> Bool {
        let target: Target
        switch screen {
        case .detail(let viewing), .actions(let viewing): target = viewing
        default: return false
        }
        guard now?.sections.find(target.action.id)?.group != target.group else { return false }
        returnToList()
        return true
    }

    /// return
    func primary() {
        switch screen {
        case .list:
            if let item = selectedItem { run(item) }
        case .actions(let target):
            let entries = actionEntries(for: target)
            if entries.indices.contains(selection) { perform(entries[selection], on: target) }
        case .detail(let target):
            openActions(target)
        case .commands:
            let commands = LauncherCommand.allCases
            if commands.indices.contains(selection) { run(commands[selection]) }
        case .editDue, .addDue:
            let choices = dueChoices
            guard choices.indices.contains(selection) else { return }
            switch choices[selection] {
            case .date(let date): chooseDue(date)
            case .clear: chooseDue(nil)
            }
        case .answer:
            back()
        case .pickSource(let purpose):
            if case .add(let draft) = purpose, selection == 0 {
                create(draft, source: nil, quote: nil)
                return
            }
            let sources = filteredSources
            let index = selection - sourceRowOffset
            if sources.indices.contains(index) { pick(sources[index], for: purpose) }
        case .pickLines:
            lineSelection.tap(lineCursor)
        case .done:
            // 완료 줄은 닫기만 (목록으로 돌아가 다른 행을 실행하지 않게)
            close()
        case .notice:
            back()
        case .consentNeeded:
            openSettings(.ai)
        case .working, .runWithAI, .draft:
            // M8의 ↩는 Goal 줄바꿈 · 초안의 ↩는 할 일이 없다 (`handleSubScreenKey`)
            break
        }
    }

    /// ⌘↩: 줄을 고른 뒤 신고 · 추가
    func commandReturn() {
        if case .pickLines = screen {
            submitLines()
        } else {
            primary()
        }
    }

    /// Tab/→ (Review 행은 ↩도): Sources 묶음 펼치기
    func expand() {
        guard screen == .list, let item = selectedItem, let target = target(for: item) else { return }
        showSources(target)
    }

    private func showSources(_ target: Target) {
        if screen == .list { viewed = (target.action.id, selection) }
        laneFocus = nil
        screen = .detail(target)
        Task { await now?.loadEvidence(target.action.id) }
    }

    /// ⌘K: 할 일 행이면 그 할 일의 동작, 아니면 명령 (빈 화면 · 안내 · 저장본 줄)
    func openActions() {
        switch screen {
        case .list:
            guard let item = selectedItem, let target = target(for: item) else {
                openCommands()
                return
            }
            openActions(target)
        case .detail(let target), .runWithAI(let target), .draft(let target?, _):
            openActions(target)
        default:
            break
        }
    }

    private func openActions(_ target: Target) {
        if screen == .list { viewed = (target.action.id, selection) }
        screen = .actions(target)
        selection = initialActionIndex(for: target)
    }

    /// 명령 패널 (로그인한 동안). esc로 목록에 돌아오면 맨 위 (`rowAfterBack`: 본 할 일 없음)
    private func openCommands() {
        guard isSignedIn, configurationError == nil else { return }
        scopeMenuSelection = nil
        viewed = nil
        screen = .commands
        selection = 0
    }

    /// esc: 한 단계 뒤로, 목록이면 입력을 지우고, 비어 있으면 닫는다
    func back() {
        switch screen {
        case .list:
            if text.isEmpty { close() } else { text = "" }
        case .editDue(let target):
            screen = .actions(target)
            // Review는 맨 위 Confirm이 아니라 떠난 Edit due 줄로 돌아온다
            selection = target.group == .review ? actionEntries(for: target).firstIndex(of: .editDue) ?? 0 : 0
        case .pickSource(.add(let draft)):
            screen = .addDue(draft)
            selection = LauncherDue.index(of: draft.due, in: dueChoices)
            pickedDate = draft.due.map(Self.pickerDate) ?? Date()
        case .pickLines(_, let purpose):
            screen = .pickSource(purpose)
            selection = 0
        case .runWithAI(let target), .draft(let target?, _):
            // M8 · 초안 → 상세 (입력한 Goal은 런처를 닫을 때까지 할 일별로 남는다)
            work?.cancel()
            screen = .detail(target)
        case .detail where laneFocusTarget != nil:
            // 갈래 버튼에서 상세로
            laneFocus = nil
        case .working:
            // 직접 추가 · 신고는 결과가 올 때까지 기다린다 (돌아가서 다시 보내면 중복)
            guard !isSubmitting else { return }
            work?.cancel()
            writeGeneration += 1
            returnToList()
        default:
            // 펼침 · ⌘K 패널(과 거기서 연 알림)은 본 할 일의 행으로 (맨 위의 다른 Review를 고른 채 두지 않게)
            returnToList()
        }
    }

    private func textChanged() {
        viewed = nil
        switch screen {
        case .list, .pickSource:
            selection = 0
            selectedID = nil
        case .actions, .detail, .commands, .answer, .done, .notice, .consentNeeded:
            screen = .list
            selection = 0
            selectedID = nil
        case .editDue, .addDue, .working, .pickLines, .runWithAI, .draft:
            break
        }
    }

    /// 할 일 행이면 ⌘K · 펼침의 대상. Hand off 행은 그 할 일이 있는 구역으로 본다.
    private func target(for item: LauncherItem) -> Target? {
        guard let action = item.action else { return nil }
        let group = item.group ?? now?.sections.find(action.id)?.group ?? TaskGroup.open(action)
        return Target(action: action, group: group)
    }

    // MARK: 실행

    func run(_ item: LauncherItem) {
        switch item {
        case .showMore(let group, _):
            caps.expand(group)
            reconcileSelection()
        case .doneToday:
            caps.toggle(.doneToday)
            reconcileSelection()
        case .failedSources, .saved:
            // 알리기만 · 읽기만 하는 줄
            break
        case .review(let action):
            // 제목만 보고 확정하지 않게 근거를 먼저 보인다. 확정은 ⌘↩ · ⌘K Confirm
            showSources(Target(action: action, group: .review))
        case .task, .done:
            if let target = target(for: item) { openActions(target) }
        case .command(let command):
            run(command)
        case .ask(let question):
            ask(question)
        case .handoff:
            if let target = target(for: item) { perform(.handoff, on: target) }
        case .sendAsSource(let text):
            send(text)
        case .addAction(let title):
            startAdd(title)
        case .signInWithGoogle:
            startGoogleSignIn()
        case .allowAI:
            openSettings(.ai)
        case .policyNotice(let notice):
            account?.acknowledgePolicyNotice()
            open(notice.url.url())
        }
    }

    private func run(_ command: LauncherCommand) {
        switch command {
        case .sendClipboard:
            guard let text = Clipboard.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                screen = .notice("The clipboard is empty.")
                return
            }
            send(text)
        case .reportMissing:
            startReportMissing()
        case .connections:
            openSettings(.connections)
        case .settings:
            // 마지막에 본 설정 페이지 (`.account`는 이제 계정 시트다, U1 PR5a)
            openSettings()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    func perform(_ entry: ActionEntry, on target: Target) {
        // ⌘K 패널 줄을 누름 · ↩: 그사이 바뀐 할 일에는 실행하지 않는다
        guard let now, !leaveIfStale() else { return }
        let id = target.action.id
        switch entry {
        case .state(let state):
            // 지금 상태 줄은 체크만 (↩가 할 일이 없다)
            guard state != WorkState(target.group) else { return }
            setState(target.action, to: state)
        case .confirm: finish("Confirmed") { await now.confirm(id) }
        case .dismiss: finish("Dismissed") { await now.dismiss(id) }
        case .handoff: finish("Copied") { _ = await now.handoff(id) }
        case .openSource: openSource(target.action)
        case .editDue:
            screen = .editDue(target)
            selection = 0
            pickedDate = target.action.dueDate.map(Self.pickerDate) ?? Date()
        case .delete: delete(target.action)
        case .runWithAI: openRun(target)
        case .stopTaskforce: stopTaskforce(target)
        }
    }

    // MARK: 진행 상태 (런처를 닫지 않는다)

    /// To Do · In Progress · Done으로 옮김: 그 행을 옮긴 구역에서 고른 채 두고, 잠시 ⌘Z로 그 전 상태로 되돌린다
    func setState(_ action: ActionSummary, to state: WorkState, undoable: Bool = true) {
        guard let now else { return }
        let previous = now.state(of: action.id)
        // Done으로 옮기면 끝나지 않은 run을 먼저 멈춘다 (옮기기 쓰기와 함께 보낸다)
        if state == .done, previous != nil, previous != .done { stopRunsBeforeLeaving(action.id) }
        let write = now.move(action.id, to: state)
        selectRow(of: action.id)
        guard let write else { return }
        if undoable, let previous {
            offerUndo(TaskUndo(action, was: previous, change: .moved))
        } else {
            clearUndo()
        }
        report(write)
    }

    /// 삭제 (⌘K Delete · ⌘⌫): 런처를 닫지 않고 그 행을 빼고 같은 자리의 다음 행을 고른다. 잠시 ⌘Z로 되살린다.
    func delete(_ action: ActionSummary) {
        guard let now else { return }
        let row = items.firstIndex { $0.group != nil && $0.action?.id == action.id }
        // 끝나지 않은 run을 먼저 멈춘다 (지우기 쓰기와 함께 보낸다)
        if now.sections.find(action.id)?.group.isDeletable == true { stopRunsBeforeLeaving(action.id) }
        guard let deleted = now.delete(action.id) else { return }
        closeTimer?.cancel()
        screen = .list
        viewed = nil
        selection = row ?? 0
        selectedID = nil
        reconcileSelection()
        offerUndo(deleted.undo)
        report(deleted.write)
    }

    /// ⌘Z: 방금 옮긴 할 일을 그 전 상태로, 지운 할 일은 지우기 전 구역으로
    func undo() {
        guard canUndo, let undo = undoOffer.take() else {
            clearUndo()
            return
        }
        switch undo.change {
        case .moved:
            guard let found = now?.sections.find(undo.action.id) else {
                clearUndo()
                return
            }
            setState(found.action, to: undo.state, undoable: false)
        case .deleted:
            guard let now else { return }
            let write = now.restore(undo)
            selectRow(of: undo.action.id)
            clearUndo()
            report(write)
        }
    }

    private func offerUndo(_ undo: TaskUndo) {
        undoOffer.offer(undo)
        let serial = undoOffer.serial
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(for: UndoOffer.window)
            guard !Task.isCancelled else { return }
            undoOffer.expire(serial)
        }
    }

    private func clearUndo() {
        undoTimer?.cancel()
        undoTimer = nil
        undoOffer.clear()
    }

    /// 목록으로 돌아가 그 할 일의 행(옮겨 간 구역)을 고른다
    private func selectRow(of id: UUID) {
        closeTimer?.cancel()
        screen = .list
        viewed = nil
        // 옮겨 간 자리가 접힌 나머지 안이면 그 섹션을 펼친다 (옮긴 행이 `Show N More` 뒤로 숨지 않게)
        if !items.contains(where: { $0.group != nil && $0.action?.id == id }), let found = now?.sections.find(id) {
            caps.expand(found.group)
        }
        let items = items
        if let index = items.firstIndex(where: { $0.group != nil && $0.action?.id == id }) {
            selection = index
            selectedID = items[index].id
        } else {
            reconcileSelection()
        }
    }

    /// 쓰기가 실패하면 (행은 제자리로 돌아간다) 알린다
    private func report(_ write: Task<Void, Never>) {
        guard let now else { return }
        now.message = nil
        Task {
            await write.value
            guard let error = now.message else { return }
            now.message = nil
            clearUndo()
            if screen == .list { screen = .notice(error) }
        }
    }

    private var isChoosingDue: Bool {
        switch screen {
        case .editDue, .addDue: true
        default: false
        }
    }

    /// 기한 고르기의 결과: 있는 할 일이면 저장, 추가 중이면 다음 단계(원문 고르기)로
    func chooseDue(_ due: LocalDate?) {
        switch screen {
        case .editDue(let target): setDue(due, on: target)
        case .addDue(let draft): startPickSource(.add(Draft(title: draft.title, due: due)))
        default: break
        }
    }

    func setDue(_ due: LocalDate?, on target: Target) {
        guard let now else { return }
        let label = due.map { "Due \(DueText.short($0, today: DueDateFormat.today()))" } ?? "Due date cleared"
        finish(label) { await now.setDue(target.action.id, due) }
    }

    /// 서버 호출 → 성공하면 "Done" 한 줄을 잠깐 보이고 닫는다. `NowStore`가 남긴 오류가 있으면 알린다.
    private func finish(_ message: String, _ operation: @escaping @MainActor () async -> Void) {
        guard let now else { return }
        now.message = nil
        let generation = beginWrite()
        // 쓰기는 창을 닫아도 끝까지 보낸다 (취소하면 서버에 반영됐는지 알 수 없다)
        Task {
            await operation()
            let error = now.message
            now.message = nil
            guard isCurrentWrite(generation) else { return }
            if let error {
                screen = .notice(error)
            } else {
                showDoneAndClose(message)
            }
        }
    }

    private func beginWrite() -> Int {
        work?.cancel()
        writeGeneration += 1
        screen = .working("Working…")
        return writeGeneration
    }

    /// 이 쓰기를 시작한 화면이 아직 그대로인지 (그사이 esc · 다시 열기로 바뀌었으면 결과를 조용히 둔다)
    private func isCurrentWrite(_ generation: Int) -> Bool {
        guard generation == writeGeneration, case .working = screen else { return false }
        return true
    }

    /// 직접 추가 · 신고를 보내는 중이라 그 진행 화면에 머문다: esc로 돌아가지 않고, 창을 다시 열어도 그대로다
    var isSubmitting: Bool {
        guard let submission else { return false }
        return isCurrentWrite(submission)
    }

    /// 직접 추가 · 신고 쓰기 시작 (`isSubmitting`)
    private func beginSubmission() -> Int {
        let generation = beginWrite()
        submission = generation
        return generation
    }

    private func endSubmission(_ generation: Int) {
        if submission == generation { submission = nil }
    }

    private func showDoneAndClose(_ message: String) {
        screen = .done(message)
        closeTimer?.cancel()
        closeTimer = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, case .done = screen else { return }
            close()
        }
    }

    private func openSource(_ action: ActionSummary) {
        guard let now else { return }
        screen = .working("Opening…")
        work = Task {
            let digest = await now.loadEvidence(action.id)
            guard !Task.isCancelled else { return }
            if let url = Self.sourceLink(digest)?.externalURL {
                open(url)
            } else {
                screen = .notice("No link to the original.")
            }
        }
    }

    /// 할 일 행 ↩ (Figma M1 `Open in Notion ↩`): 원문 링크가 있으면 열고, 없으면 ⌘K 패널 (전과 같다).
    /// 근거를 아직 읽지 못했으면 읽은 뒤 정한다
    func openSourceOrActions(_ target: Target) {
        guard let now else { return }
        let id = target.action.id
        if let digest = now.evidence[id] {
            if let url = Self.sourceLink(digest)?.externalURL { open(url) } else { openActions(target) }
            return
        }
        if now.evidenceFailed.contains(id) {
            openActions(target)
            return
        }
        if screen == .list { viewed = (id, selection) }
        screen = .working("Opening…")
        work = Task {
            let digest = await now.loadEvidence(id)
            guard !Task.isCancelled, case .working = screen else { return }
            if let url = Self.sourceLink(digest)?.externalURL {
                open(url)
            } else {
                screen = .actions(target)
                selection = initialActionIndex(for: target)
            }
        }
    }

    /// 할 일 행 ↩ · Open source가 여는 근거 줄 (`EvidenceDigest.openLink`). 초안 receipt(`taskforce://artifacts`)가 가장 최근 근거여도
    /// 원래 원문 링크가 있으면 그것 (Figma M1: 초안이 있어도 `Open in Notion`), 없을 때만 초안
    static func sourceLink(_ digest: EvidenceDigest?) -> EvidenceLine? {
        guard let digest else { return nil }
        func isDraft(_ line: EvidenceLine) -> Bool { line.externalURL.flatMap(ArtifactLink.parse) != nil }
        if let link = digest.openLink, !isDraft(link) { return link }
        return digest.lines.last { $0.externalURL != nil && !isDraft($0) } ?? digest.openLink
    }

    /// 초안 링크(`taskforce://artifacts/<id>`, receipt 원문 슬립)는 런처 안 초안 화면, 나머지는 브라우저 · 앱으로 열고 닫는다
    func open(_ url: URL) {
        if let id = ArtifactLink.parse(url) {
            openDraft(id: id)
            return
        }
        NSWorkspace.shared.open(url)
        close()
    }

    /// `tab`이 없으면 마지막에 본 페이지 (`SettingsOpener.open`)
    func openSettings(_ tab: MacSettingsTab? = nil) {
        close()
        SettingsOpener.open(tab)
    }

    // MARK: 물어보기 · 원문 보내기

    private func ask(_ question: String) {
        guard let services else { return }
        screen = .working("Asking…")
        work = Task {
            do {
                let response = try await services.api.ask(question)
                guard !Task.isCancelled else { return }
                screen = .answer(question: question, response: response, lines: response.citations.map(EvidenceLine.init))
                selection = 0
            } catch is CancellationError {
            } catch let error as APIError {
                guard !Task.isCancelled else { return }
                screen = Self.screen(for: error, rateLimited: "Too many questions. Try again in a moment.", missing: "Ask isn't available yet.")
            } catch {
                screen = .notice(error.userMessage)
            }
        }
    }

    private func send(_ text: String) {
        guard let services else { return }
        guard let request = PastedSource.request(for: text) else {
            screen = .notice("That's too long to send as one source.")
            return
        }
        let generation = beginWrite()
        Task {
            do {
                _ = try await services.api.createSource(request)
                guard isCurrentWrite(generation) else { return }
                showDoneAndClose("Sent")
            } catch let error as APIError {
                guard isCurrentWrite(generation) else { return }
                screen = Self.screen(for: error, rateLimited: "Too many requests. Try again in a moment.", missing: error.userMessage)
            } catch {
                guard isCurrentWrite(generation) else { return }
                screen = .notice(error.userMessage)
            }
        }
    }

    private static func screen(for error: APIError, rateLimited: String, missing: String) -> Screen {
        if error.isConsentRequired { return .consentNeeded }
        switch error {
        case .server(_, .rateLimited, _): return .notice(rateLimited)
        case .server(404, _, _), .unexpectedStatus(404): return .notice(missing)
        default: return .notice(error.userMessage)
        }
    }

    // MARK: 빠진 할 일 신고 · 직접 추가

    private func startReportMissing() {
        text = ""
        startPickSource(.reportMissing)
    }

    /// "Add “…”": 기한 → 원문(없어도 됨) → 줄 → 추가. 제목은 입력창에 그대로 둔다.
    private func startAdd(_ title: String) {
        screen = .addDue(Draft(title: title, due: nil))
        selection = 0
        pickedDate = Date()
    }

    private func startPickSource(_ purpose: SourcePurpose) {
        guard let services else { return }
        work?.cancel()
        screen = .pickSource(purpose)
        selection = 0
        sourcesLoaded = false
        work = Task {
            let sources = (try? await services.reads.recentSources(limit: 30)) ?? []
            guard !Task.isCancelled else { return }
            // 읽는 중인 원문은 결과가 나오기 전이라 신고를 받지 않는다
            recentSources = sources.filter { $0.processingStatus == .done || $0.processingStatus == .failed }
            sourcesLoaded = true
        }
    }

    private func pick(_ source: SourceSummary, for purpose: SourcePurpose) {
        guard let services else { return }
        screen = .working("Opening…")
        work = Task {
            do {
                let detail = try await services.reads.sourceDetail(id: source.id)
                guard !Task.isCancelled else { return }
                let text = SourceText(detail.source.rawText)
                sourceText = text
                lineSelection.clear()
                lineCursor = text.lines.first { !$0.isBlank }?.index ?? 0
                screen = .pickLines(detail.source, purpose)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                screen = .notice(error.userMessage)
            }
        }
    }

    var selectedQuote: String? {
        guard let range = lineSelection.range else { return nil }
        return sourceText?.quote(lines: range)
    }

    /// ⌘↩: 고른 줄로 신고하거나, 그 줄을 근거로 추가한다
    func submitLines() {
        guard case .pickLines(let source, let purpose) = screen, let quote = selectedQuote else { return }
        guard quote.utf16.count <= SourceText.maxQuoteLength else {
            screen = .notice("Pick fewer lines (up to \(SourceText.maxQuoteLength) characters).")
            return
        }
        switch purpose {
        case .reportMissing: reportMissing(source: source, quote: quote)
        case .add(let draft): create(draft, source: source, quote: quote)
        }
    }

    private func reportMissing(source: SourceRecord, quote: String) {
        guard let services else { return }
        let generation = beginSubmission()
        Task {
            defer { endSubmission(generation) }
            do {
                let result = try await services.api.reportMissing(sourceID: source.id, quote: quote)
                // 그사이 로그아웃 · 계정 전환했으면 다시 읽지 않는다 (전 계정의 쓰기)
                guard isCurrentWrite(generation) else { return }
                await now?.load()
                guard isCurrentWrite(generation) else { return }
                let title = result.action.title
                showDoneAndClose(result.status == .created ? "Added “\(title)”" : "Already tracked “\(title)”")
            } catch let error as APIError {
                guard isCurrentWrite(generation) else { return }
                if case .server(_, .rateLimited, _) = error {
                    screen = .notice("Too many reports. Try again in a moment.")
                } else {
                    screen = .notice(error.userMessage)
                }
            } catch {
                guard isCurrentWrite(generation) else { return }
                screen = .notice(error.userMessage)
            }
        }
    }

    private func create(_ draft: Draft, source: SourceRecord?, quote: String?) {
        guard let services else { return }
        let generation = beginSubmission()
        Task {
            defer { endSubmission(generation) }
            do {
                let result = try await services.api.createAction(
                    title: draft.title, dueDate: draft.due, sourceID: source?.id, quote: quote
                )
                guard isCurrentWrite(generation) else { return }
                await now?.load()
                guard isCurrentWrite(generation) else { return }
                showDoneAndClose(result.status == .created ? "Added" : "Already tracked")
            } catch {
                guard isCurrentWrite(generation) else { return }
                screen = .notice(error.userMessage)
            }
        }
    }

    // MARK: Run with AI · 갈래 · 초안 · 중단 (U2 Mac)

    /// 하위 화면 머리 (Figma M8 `‹ <할 일> › Run with AI`). 검색줄 화면이면 nil
    var crumb: (task: String?, screen: String)? {
        switch screen {
        case .runWithAI(let target): (target.action.title, "Run with AI")
        case .draft(let target, _): (target?.action.title, "Draft")
        default: nil
        }
    }

    /// 머리가 검색줄 대신 경로인 화면 (목록은 흐리게, Figma M8)
    var isSubScreen: Bool { crumb != nil }

    /// `Run with AI…`를 보일지 · 켤지. To Do · In Progress만 (Review는 확인 전, Done은 서버가 받지 않는다)
    func runAvailability(for target: Target) -> RunAvailability {
        guard let runs, target.group == .toDo || target.group == .inProgress else { return .hidden }
        return runs.availability(for: target.action.id, signedIn: isSignedIn, refresh: refreshState)
    }

    /// 그 할 일에 멈출 run이 있나 (`Stop Taskforce`)
    func canStop(_ target: Target) -> Bool {
        guard let runs, runs.isAvailable else { return false }
        return !runs.stopTargets(for: target.action.id).isEmpty
    }

    /// 상세의 Taskforce 갈래 (실행을 쓸 수 없거나 보일 것이 없으면 nil)
    func lane(for id: UUID) -> RunLane? {
        guard let runs, runs.isAvailable else { return nil }
        let lane = runs.lane(for: id)
        return lane.isVisible ? lane : nil
    }

    private func laneDrafts(_ target: Target?) -> [Artifact]? {
        guard let target, let drafts = lane(for: target.action.id)?.drafts, !drafts.isEmpty else { return nil }
        return drafts
    }

    /// 갈래 버튼(`View Draft`)으로 옮긴 상세의 할 일 (Tab · →, ↩로 연다)
    var laneFocusTarget: Target? {
        guard case .detail = screen, let target = focusedTarget, laneFocus == target.action.id, laneDrafts(target) != nil else { return nil }
        return target
    }

    private func focusLane() {
        guard let target = focusedTarget, laneDrafts(target) != nil else { return }
        laneFocus = target.action.id
    }

    private func openFocusedDraft() {
        guard let target = laneFocusTarget, let draft = laneDrafts(target)?.first else { return }
        openDraft(draft, for: target)
    }

    /// M8 Goal (지금 화면의 할 일 것)
    var goal: String {
        get { if case .runWithAI(let target) = screen { goals[target.action.id] ?? "" } else { "" } }
        set { if case .runWithAI(let target) = screen { goals[target.action.id] = newValue } }
    }

    /// M8의 할 일을 지금 목록에서 다시 찾은 값. 연 뒤에 지워졌거나 · 끝났거나 · Review로 갔으면(다른 기기) nil
    private var runTarget: Target? {
        guard case .runWithAI(let opened) = screen, let found = now?.sections.find(opened.action.id) else { return nil }
        let target = Target(action: found.action, group: found.group)
        return runAvailability(for: target) == .hidden ? nil : target
    }

    /// Start를 누를 수 있나: 시작할 수 있는 할 일 · 빈 Goal 아님 · 보내는 중 아님
    var canStartRun: Bool {
        guard let target = runTarget, let runs, runAvailability(for: target).isEnabled, !runs.starting.contains(target.action.id)
        else { return false }
        return !CreateRunRequest(actionID: target.action.id, request: goal).isEmpty
    }

    /// M8 열기 (⌘R · ⌘K `Run with AI…`). Use 칩은 이 할 일의 근거를 읽어 채운다
    func openRun(_ target: Target) {
        guard let runs, runAvailability(for: target).isEnabled else { return }
        if screen == .list { viewed = (target.action.id, selection) }
        laneFocus = nil
        screen = .runWithAI(target)
        draftSources = nil
        let id = target.action.id
        work?.cancel()
        work = Task {
            let sources = await runs.draftSources(actionID: id)
            guard !Task.isCancelled, case .runWithAI(let current) = screen, current.action.id == id else { return }
            draftSources = sources ?? []
        }
    }

    /// ⌘↩ Start: `POST /runs` 한 번 (보내는 동안 다시 눌러도 무시). 202면 상세로 돌아가 갈래 working.
    /// 409 동의 화면 · 404 · 429 · 그 밖은 한 줄 알림 (그 할 일을 아직 보고 있을 때만)
    func startRun() {
        guard case .runWithAI = screen else { return }
        // 연 뒤에 할 일이 바뀌었으면(지워짐 · 끝남 · Review) 보내지 않고 목록으로 (`leaveIfStale`처럼)
        guard let target = runTarget else { return returnToList() }
        guard canStartRun, let runs else { return }
        let request = goal
        let id = target.action.id
        Task {
            let result = await runs.start(actionID: id, request: request)
            let viewing = switch screen {
            case .runWithAI(let current), .detail(let current): current.action.id == id
            default: false
            }
            switch result {
            case .started:
                goals[id] = nil
                if case .runWithAI = screen, viewing { screen = .detail(target) }
            case .failed(.consentNeeded):
                if viewing { screen = .consentNeeded }
            case .failed(let failure):
                if viewing, let message = failure.message { screen = .notice(message) }
            case .ignored:
                break
            }
        }
    }

    /// 초안 보기 (갈래 `View Draft`)
    func openDraft(_ artifact: Artifact, for target: Target?) {
        if screen == .list, let target { viewed = (target.action.id, selection) }
        laneFocus = nil
        screen = .draft(target, artifact)
    }

    /// 초안 링크 (`taskforce://artifacts/<id>`: receipt 원문 슬립 · 앱 밖에서 연 링크). 읽어 둔 초안이 없으면 RLS로 읽는다
    func openDraft(id: UUID) {
        guard let runs else { return }
        // 로그인 상태를 아직 따라가지 않았으면(`sessionChanged` 전) 그 뒤에 연다: 첫 로그인의 화면 정리에 지워지지 않게
        guard isSignedIn, signedInUserID == lastUserID else {
            pendingDraft = id
            return
        }
        if screen == .list, let target = detailTarget { viewed = (target.action.id, selection) }
        work?.cancel()
        screen = .working("Opening…")
        work = Task {
            let result = await runs.draft(id: id)
            guard !Task.isCancelled, case .working = screen else { return }
            switch result {
            case .found(let artifact):
                let found = now?.sections.find(artifact.actionID)
                screen = .draft(found.map { Target(action: $0.action, group: $0.group) }, artifact)
            case .notFound: screen = .notice(ArtifactLink.notFoundMessage)
            case .failed(let message): screen = .notice(message)
            case .cancelled: returnToList()
            }
        }
    }

    /// 초안 Copy가 쓰는 붙여넣기 판 (테스트는 이름 붙인 판으로 바꾼다)
    @ObservationIgnored var pasteboard = NSPasteboard.general

    /// ⌘C · 막대 Copy: 초안 제목 + 본문 (본문을 지운 초안은 없음). 사용자 결정 (2026-10-04, Raycast Copy to Clipboard):
    /// 복사하고 런처의 완료 줄 `Copied`(`showDoneAndClose`, Hand off와 같다)를 잠깐 보인 뒤 닫는다
    func copyDraft() {
        guard case .draft(_, let artifact) = screen, !artifact.isPurged else { return }
        Clipboard.copy("\(artifact.title)\n\n\(artifact.body)", to: pasteboard)
        showDoneAndClose("Copied")
    }

    /// Stop Taskforce (⌘. · ⌘K): 그 할 일의 끝나지 않은 run을 모두 멈춘다. ⌘K 패널이면 목록으로 돌아가 갈래를 보인다
    func stopTaskforce(_ target: Target) {
        guard let runs, canStop(target) else { return }
        if case .actions = screen { returnToList() }
        let id = target.action.id
        Task {
            guard !(await runs.stop(actionID: id)), let message = runs.message else { return }
            runs.message = nil
            switch screen {
            case .list, .detail, .draft: screen = .notice(message)
            default: break
            }
        }
    }

    /// 할 일을 Delete · Done으로 옮길 때 끝나지 않은 run을 먼저 멈춘다 (`RunStop`: 목록에서 사라진 할 일이 크레딧을 쓰지 않게)
    private func stopRunsBeforeLeaving(_ id: UUID) {
        guard let runs, !runs.stopTargets(for: id).isEmpty else { return }
        // 실패해도 알리지 않는다 (서버도 끝낸 · 버린 할 일의 다음 단계를 거절한다): 남은 오류 글을 지운다
        Task { if !(await runs.stop(actionID: id)) { runs.message = nil } }
    }

    // MARK: 로그인

    /// 런처의 "Sign in with Google" 행: 로그인 화면의 버튼과 같은 흐름을 런처 창 위에 띄운다
    private func startGoogleSignIn() {
        guard let session, let anchor = presentationAnchor() else { return }
        suspendsAutoClose = true
        NSApplication.shared.activate()
        GoogleSignInFlow.signIn(session: session, presenting: anchor) { [weak self] in
            guard let self else { return }
            self.suspendsAutoClose = false
            self.focusRequest += 1
        }
    }

    /// 기한 선택기의 Date ↔ 기한 날짜 (선택기는 기기 시간대로 날짜를 보여준다)
    static func pickerDate(_ date: LocalDate) -> Date {
        var components = DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)
        components.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }
}

extension LauncherModel.Screen {
    /// 상세로 포커스 (Tab · →, Review 행 ↩)
    var isDetail: Bool {
        if case .detail = self { true } else { false }
    }
}

#endif
