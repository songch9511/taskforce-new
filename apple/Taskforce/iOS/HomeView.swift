#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// iPhone 한 화면 (Figma 156:6 P1 190:3668 · 오프라인 P10 292:2716 · 큰 글자 P11 292:2858):
/// 큰 제목 `Tasks` → 검색칸 `Search 23 tasks` → 상태 줄(오프라인 · 새로고침 실패 · 실패 원문) → Review 카드 한 장(`1 of 4`, 위에 `Show All 4 ›`)
/// → In Progress · To Do · Done Today (머리에 개수). 순서는 서버가 정한 그대로 보여 준다 (구역 나누기는 `TaskBoard`).
/// 이번 실행에서 `/now`를 받기 전(처음 불러오는 중 · 오프라인 · 새로고침 실패)에는 이 기기의 저장본(제목 · 기한 · 상태만)을 읽기만 한다.
/// 오프라인이거나 저장본이면 Confirm · Dismiss · 상태 바꾸기 · 삭제를 막는다 (`PhoneHome.canWrite`, 모아 두었다 보내지 않는다).
/// 행을 누르면 근거 한 줄을 펼친다. 바뀐 할 일이면 그때 `seen`을 한 번 보낸다 (`SeenTracker.open`, 실패해도 다시 보내지 않음).
/// 상태는 To Do · In Progress · Done 세 이름으로만 옮긴다 (`NowStore.move`):
/// - 왼쪽 원: 열린 할 일 → Done, 끝낸 할 일 → 끝내기 전 상태
/// - 밀기: To Do는 오른쪽 In Progress · 왼쪽 Done, In Progress는 오른쪽 To Do · 왼쪽 Done, Done Today는 오른쪽 To Do
/// - 길게 누르기: 세 상태 (지금 상태에 체크)
/// 삭제: 왼쪽으로 밀기(Done 옆, 끝까지 밀면 Done) · 길게 누르기 맨 아래. 지운 뒤 5초 동안 아래에 "Deleted  Undo" (`NowStore.delete` · `restore`)
/// Account 버튼은 Figma P1에 없지만 로그아웃 · 계정 삭제 경로라 왼쪽 위에 둔다 (U9 재판정).
struct HomeView: View {
    let userID: UUID
    let email: String?

    @Environment(NowStore.self) private var store
    @Environment(AccountStore.self) private var account
    @Environment(ActionChangeFeed.self) private var changes
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded: UUID?
    /// 누른 알림의 할 일: 그 행을 잠시 칠한다 (Review면 그 카드를 먼저 보인다)
    @State private var highlighted: UUID?
    @State private var reviewFocus: UUID?
    @State private var scrollTarget: UUID?
    @State private var accountRoute: AccountRoute?
    @State private var addingTask = false
    /// 직접 추가가 끝날 때마다 늘린다 (가벼운 햅틱)
    @State private var addedTasks = 0
    /// 방금 지운 할 일: 잠시 아래에 "Deleted  Undo" (`UndoOffer`)
    @State private var undo = UndoOffer()
    /// 지울 때마다 늘린다 (가벼운 햅틱)
    @State private var deletions = 0
    @State private var promptingProfile = false
    /// 동의 전인데 연결이 있으면 로그인 뒤 한 번 (목록은 그대로 보인다)
    @State private var promptingConsent = false
    @State private var consentPrompted = false
    /// 검색칸 (`TaskFilter`: 찾는 동안 네 구역 모두 거른다)
    @State private var query = ""
    /// 바뀜 점을 지우고 `seen`을 보낸 할 일 (`SeenTracker`, 새 `/now`가 오면 서버 값이 진실)
    @State private var seen = SeenTracker()
    /// `Show All 4 ›`: Review 카드를 모두 보이는 화면
    @State private var showingAllReviews = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            content
                .background(TFColor.bgCanvas)
                .overlay(alignment: .bottom) { undoBar }
                .navigationTitle("Tasks")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            accountRoute = .home
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel("Account")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            addingTask = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New Task")
                    }
                }
                .navigationDestination(isPresented: $showingAllReviews) { allReviews }
        }
        // 나타날 때마다, 그리고 Realtime 신호가 올 때마다
        .task(id: changes.revision) { await store.load() }
        // 새 `/now`(또는 저장본)가 보이면 서버의 바뀜이 진실이다: 보낸 seen 기록을 비운다
        .onChange(of: store.refresh.shownAt) { seen.refreshed(changed: changedIDs) }
        // 연결이 동기화 중이면 앞에 있는 동안 몇 초마다 연결을 다시 읽고, 끝나면 지금 할 일을 다시 불러온다
        .task(id: account.anySyncing && scenePhase == .active) {
            guard account.anySyncing, scenePhase == .active else { return }
            await account.followSync()
        }
        .onChange(of: account.syncFinished) { Task { await store.load() } }
        // 알림 권한: 연결이 생긴 뒤 다른 시트가 없을 때 한 번 (첫 실행에는 묻지 않는다)
        .onChange(of: readyForPushPrompt, initial: true) { _, ready in
            guard ready else { return }
            Task { await PushCenter.shared.requestIfNeeded(hasConnections: account.hasConnections) }
        }
        // 누른 알림: 그 할 일로
        .onChange(of: PushCenter.shared.target, initial: true) { _, target in
            if target != nil { openNotification() }
        }
        .task {
            await account.load()
            // 로그아웃으로 사라졌으면 묻지 않는다: 묻지 않고 "물었음"만 남기면 이 기기에서 다시 묻지 않는다 (읽기는 취소돼도 끝까지 돈다)
            guard !Task.isCancelled else { return }
            promptProfileIfNeeded()
            promptConsentIfNeeded()
        }
        // 처리방침 변경 안내: 나타날 때와 앞으로 돌아올 때마다 (못 읽으면 조용히 넘긴다)
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await account.loadPolicyNotice(userID: userID)
        }
        .sheet(item: $accountRoute) { route in
            AccountSheet(email: email, initialRoute: route)
        }
        .sheet(isPresented: $addingTask) {
            NewTaskSheet { addedTasks += 1 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: addedTasks)
        .sensoryFeedback(.impact(weight: .light), trigger: deletions)
        .task(id: undo.serial) {
            // 5초 뒤 거둔다 (그사이 새로 지우면 새로 센다)
            guard undo.pending != nil else { return }
            let serial = undo.serial
            try? await Task.sleep(for: UndoOffer.window)
            guard !Task.isCancelled else { return }
            withAnimation(Self.move) { undo.expire(serial) }
        }
        .sheet(isPresented: $promptingProfile, onDismiss: promptConsentIfNeeded) {
            NavigationStack {
                ProfileForm(dismissOnSave: true)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $promptingConsent) {
            ConsentPrompt()
        }
        .messageAlert($store.message)
    }

    @ViewBuilder
    private var content: some View {
        if store.response == nil, savedCopy == nil {
            if case .offlineEmpty = store.refreshState {
                offlineEmpty
            } else if store.loaded, let error = store.loadError {
                VStack(spacing: TFSpace.md) {
                    Text(error)
                        .font(TFFont.callout)
                        .foregroundStyle(TFColor.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await store.load() } }
                        .buttonStyle(.bordered)
                }
                .padding(TFSpace.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                list
                    .overlay {
                        if isEmpty { emptyState }
                    }
                    // 누른 알림의 할 일로
                    .onChange(of: scrollTarget) { _, id in
                        guard let id else { return }
                        scrollTarget = nil
                        withAnimation { proxy.scrollTo(id.uuidString, anchor: .center) }
                    }
            }
        }
    }

    /// 오프라인 + 보일 목록 없음 (이 기기에 저장본도 없음): 상태 줄 + 가운데 빈 화면 (Mac M20과 같은 문장, iPhone 이름)
    private var offlineEmpty: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLines
                .padding(.horizontal, TFSpace.lg)
                .padding(.top, TFSpace.sm)
            EmptyState(systemImage: nil, title: "Nothing saved on this iPhone yet", message: "Tasks appear after Taskforce connects once.")
        }
    }

    private var isEmpty: Bool {
        let listing = listing
        return query.isEmpty && listing.review.isEmpty && listing.groups.isEmpty && store.response?.weeklyCheck == nil && failedSources.count == 0
    }

    private var today: LocalDate { DueDateFormat.today() }

    // MARK: 보이는 목록 (이번 실행에서 받은 목록 또는 저장본)

    /// 이번 실행에서 `/now`를 받기 전에 보이는 이 기기의 저장본
    private var savedCopy: SavedNow? { store.response == nil ? store.savedCopy : nil }

    /// 보내기를 막는지 (오프라인 · 저장본, P10)
    private var canWrite: Bool { PhoneHome.canWrite(store.refreshState, showingSavedCopy: savedCopy != nil) }

    /// 서버가 바뀜이라 한 할 일 (Review · In Progress · To Do)
    private var changedIDs: Set<UUID> { store.board.now?.changedIDs ?? [] }

    private var failedSources: FailedSources { store.response?.failedSources ?? .empty }

    /// 한 행. 저장본 행은 서버 id가 없어 읽기만 한다 (`action == nil`)
    private struct Row: Identifiable {
        let id: String
        let action: ActionSummary?
        let title: String
        let due: LocalDate?
        let urgent: Bool
    }

    private struct Listing {
        var review: [Row] = []
        /// In Progress · To Do · Done Today 중 비지 않은 구역
        var groups: [(group: TaskGroup, rows: [Row])] = []
        /// 찾기 전 열린 할 일 수 (Review + In Progress + To Do, 검색칸 자리표시)
        var openCount = 0
    }

    private var listing: Listing {
        let today = today
        if let saved = savedCopy {
            let now = Date()
            func rows(_ group: TaskGroup) -> [Row] {
                PhoneHome.savedRows(saved, in: group, matching: query, now: now).map { row in
                    let due = row.task.dueDate
                    return Row(
                        id: "saved-\(row.id)", action: nil, title: row.task.title, due: due,
                        urgent: group != .doneToday && DueText.isUrgent(due: due, reasons: [], today: today)
                    )
                }
            }
            return Listing(
                review: rows(.review),
                groups: [TaskGroup.inProgress, .toDo, .doneToday].map { ($0, rows($0)) }.filter { !$0.rows.isEmpty },
                openCount: TaskScope.allTasks.count(in: saved, now: now)
            )
        }
        let board = store.board
        let all = board.sections()
        let shown = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? all : board.sections(matching: query)
        func row(_ action: ActionSummary, reasons: [RankReason], done: Bool = false) -> Row {
            Row(
                id: action.id.uuidString, action: action, title: action.title, due: action.dueDate,
                urgent: !done && DueText.isUrgent(due: action.dueDate, reasons: reasons, today: today)
            )
        }
        let groups: [(group: TaskGroup, rows: [Row])] = [
            (.inProgress, shown.inProgress.map { row($0.action, reasons: $0.reasons) }),
            (.toDo, shown.toDo.map { row($0.action, reasons: $0.reasons) }),
            (.doneToday, shown.doneToday.map { row($0, reasons: [], done: true) }),
        ]
        return Listing(
            review: shown.review.map { row($0, reasons: []) },
            groups: groups.filter { !$0.rows.isEmpty },
            openCount: TaskScope.allTasks.count(in: all, changed: [])
        )
    }

    private var list: some View {
        let listing = listing
        // 누른 알림의 확인 요청이면 그 카드를 먼저
        let reviewIndex = listing.review.firstIndex { $0.action?.id == reviewFocus } ?? 0
        return List {
            searchField(count: listing.openCount)
                .plainRow(top: TFSpace.sm, bottom: TFSpace.md)
            statusLines
                .plainRow(top: TFSpace.sm, bottom: TFSpace.sm)
            reconnectBanner
            consentBanner
            policyBanner
            if listing.review.indices.contains(reviewIndex) {
                reviewHeader(count: listing.review.count)
                reviewCard(listing.review[reviewIndex], index: reviewIndex, count: listing.review.count)
                    .plainRow(top: 0, bottom: 0)
            }
            ForEach(listing.groups, id: \.group) { section in
                // 구역 사이 20 (Figma Content gap)
                sectionHeader(section.group.title, count: section.rows.count)
                    .plainRow(top: section.group == listing.groups.first?.group && listing.review.isEmpty ? TFSpace.sm : 20, bottom: TFSpace.xs)
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    taskRow(row, group: section.group)
                        .id(row.id)
                        // 보이는 원은 왼쪽 16에서 시작한다 (누르는 칸 44가 원보다 11 넓다)
                        .listRowInsets(EdgeInsets(top: 0, leading: TFSpace.lg - 11, bottom: 0, trailing: TFSpace.lg))
                        .listRowBackground(highlighted != nil && highlighted == row.action?.id ? TFColor.bgSurface : TFColor.bgCanvas)
                        .listRowSeparatorTint(TFColor.borderDefault)
                        .listRowSeparator(index == 0 ? .hidden : .automatic, edges: .top)
                }
            }
            if store.response?.weeklyCheck != nil {
                WeeklyCheckCard { answer in Task { await store.answerWeekly(answer) } }
                    .plainRow(top: TFSpace.xl, bottom: TFSpace.lg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, 0)
        .refreshable {
            await store.load()
            await account.reloadConnections()
        }
    }

    // MARK: 검색칸 · 상태 줄 · 섹션 머리

    /// Figma Search (205:2514): settings/fill 면 44 · r12. 자리표시는 회색 면 위 4.5:1을 지키는 text/secondary-selected
    /// (Figma는 text/secondary, 다크 settings/fill 위 4.06:1. Mac 설정 검색칸 · `KeyHint(onFill:)`와 같은 짝)
    private func searchField(count: Int) -> some View {
        let prompt = PhoneHome.searchPrompt(count: count, saved: savedCopy != nil || store.refreshState.showsSavedTasks)
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(TFFont.body)
                .foregroundStyle(TFColor.textSecondarySelected)
                .accessibilityHidden(true)
            // 칸 높이 전체(44)를 눌러도 입력이 시작된다
            TextField(prompt, text: $query, prompt: Text(prompt).foregroundStyle(TFColor.textSecondarySelected))
                .font(TFFont.body)
                .foregroundStyle(TFColor.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(TFFont.body)
                        .foregroundStyle(TFColor.textSecondarySelected)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, query.isEmpty ? 10 : 0)
        .frame(minHeight: 44)
        .background(TFColor.settingsFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 목록 위 상태 줄 (Figma P10 `Offline status`): 오프라인 · 새로고침 실패(401이면 로그아웃 · 로그인 안내) · 실패 원문 (U1 PR4 문구)
    @ViewBuilder
    private var statusLines: some View {
        let state = store.refreshState
        if let text = statusText {
            statusLine(systemImage: state.isOffline ? "wifi.slash" : "exclamationmark.triangle", text: text) {
                if case .refreshFailed = state {
                    Button("Try Again") { Task { await store.load() } }
                        .font(TFFont.callout.weight(.semibold))
                        .foregroundStyle(TFColor.textPrimary)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        if failedSources.count > 0 {
            statusLine(systemImage: "exclamationmark.triangle", text: failedSources.title) {
                if let latest = failedSources.latestAt {
                    Text(WhenText.label(latest))
                        .font(TFFont.callout)
                        .foregroundStyle(TFColor.textSecondary)
                        .fixedSize()
                }
            }
        }
    }

    /// 오프라인 · 새로고침 실패 문장 (`RefreshState.statusText`). 401이면 다시 시도보다 로그아웃 · 로그인이 답이라 그 안내
    private var statusText: String? {
        if case .refreshFailed = store.refreshState, store.authFailed, let error = store.loadError { return error }
        return store.refreshState.statusText()
    }

    private func statusLine<Trailing: View>(systemImage: String, text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) {
            Image(systemName: systemImage)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
                .frame(minWidth: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            trailing()
        }
    }

    /// 섹션 머리 (Figma `Header · In Progress`): 이름 15 semibold + 오른쪽 개수 15 보조 색. VoiceOver 머리 "In Progress, 5"
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(TFFont.calloutEmphasis)
                .foregroundStyle(TFColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)")
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Review

    /// Figma `Header · Review`: `Review` + 오른쪽 `Show All 4 ›`(누르는 칸 44). 하나뿐이면 이름만
    private func reviewHeader(count: Int) -> some View {
        HStack(alignment: .center, spacing: TFSpace.xs) {
            Text("Review")
                .font(TFFont.calloutEmphasis)
                .foregroundStyle(TFColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            if count > 1 {
                Button {
                    showingAllReviews = true
                } label: {
                    HStack(spacing: TFSpace.xs) {
                        Text("Show All \(count)")
                        Image(systemName: "chevron.right")
                            .font(TFFont.footnote.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(TFFont.callout)
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 44)
        .plainRow(top: 0, bottom: TFSpace.sm)
    }

    /// Review 카드. 저장본이면 제목 · 기한만 있고 버튼은 꺼진다. 오프라인이면 버튼 아래 P10 문장
    private func reviewCard(_ row: Row, index: Int, count: Int) -> some View {
        let action = row.action
        return ReviewCard(
            title: row.title,
            value: row.due.map { DueText.short($0, today: today) },
            reason: action.map { ConfirmReasonText.label($0.confirmReasons) },
            position: PhoneHome.reviewPosition(index, of: count),
            changed: action.map { seen.showsDot($0.id, changed: changedIDs) } ?? false,
            busy: action.map { store.busy.contains($0.id) } ?? false,
            canAct: canWrite,
            note: store.refreshState.isOffline ? "Confirm and Dismiss wait for a connection. Nothing is saved for later." : nil,
            onConfirm: { if let id = action?.id { Task { await store.confirm(id) } } },
            onDismiss: { if let id = action?.id { Task { await store.dismiss(id) } } }
        ) {
            if let id = action?.id, let digest = store.evidence[id], let lead = digest.lead {
                SourceSlip(line: lead) { openURL($0) }
            }
        }
        .id(row.id)
        .task(id: action?.id) {
            if let id = action?.id { await store.loadEvidence(id) }
        }
    }

    /// `Show All 4 ›`: Review 카드를 모두 (`1 of 4` … `4 of 4`). 다 처리하면 목록으로 돌아간다
    private var allReviews: some View {
        let reviews = listing.review
        return List {
            ForEach(Array(reviews.enumerated()), id: \.element.id) { index, row in
                reviewCard(row, index: index, count: reviews.count)
                    .plainRow(top: TFSpace.sm, bottom: TFSpace.md)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TFColor.bgCanvas)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: reviews.isEmpty) { _, empty in
            if empty { showingAllReviews = false }
        }
    }

    // MARK: In Progress · To Do · Done Today

    /// 행이 다른 구역으로 옮겨 갈 때 · 지울 때 · Undo 막대
    private static let move = Animation.snappy(duration: 0.25)

    @ViewBuilder
    private func taskRow(_ row: Row, group: TaskGroup) -> some View {
        if let action = row.action {
            let id = action.id
            let done = group == .doneToday
            let canWrite = canWrite
            TaskRow(
                title: row.title,
                due: row.due.map { DueText.short($0, today: today) },
                urgent: row.urgent,
                done: done,
                changed: seen.showsDot(id, changed: changedIDs),
                markLabel: done ? "Mark \((store.toggleTarget(id) ?? .toDo).title)" : "Mark Done",
                // 원: 열린 할 일은 Done Today로, 끝낸 할 일은 끝내기 전 구역으로 옮겨 간다
                onToggle: canWrite ? { withAnimation(Self.move) { _ = store.toggle(id) } } : nil,
                onOpen: { open(id) },
                openLabel: expanded == id ? "Hide Source" : "Show Source"
            ) {
                expandedEvidence(for: id)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if canWrite, let state = Self.swipeStates(group).leading { swipeButton(id, to: state) }
            }
            // 끝까지 밀면 Done (첫 버튼). Done이 없는 Done Today는 끝까지 밀어도 지우지 않는다
            .swipeActions(edge: .trailing, allowsFullSwipe: Self.swipeStates(group).trailing != nil) {
                if canWrite {
                    if let state = Self.swipeStates(group).trailing { swipeButton(id, to: state) }
                    if group.isDeletable {
                        Button("Delete", role: .destructive) { delete(id) }
                    }
                }
            }
            .contextMenu {
                if canWrite, let current = WorkState(group) {
                    Picker("Status", selection: Binding(get: { current }, set: { move(id, to: $0) })) {
                        ForEach(WorkState.allCases, id: \.self) { state in
                            Label(state.title, systemImage: Self.symbolName(state)).tag(state)
                        }
                    }
                    .pickerStyle(.inline)
                    if group.isDeletable {
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(id) }
                    }
                }
            }
        } else {
            // 저장본: 읽기만 (서버 id가 없다)
            TaskRow(
                title: row.title,
                due: row.due.map { DueText.short($0, today: today) },
                urgent: row.urgent,
                done: group == .doneToday,
                onToggle: nil
            )
        }
    }

    /// 행을 누름: 근거를 펼치고 접는다. 펼칠 때 바뀐 할 일이면 `seen`을 한 번 보낸다 (점은 바로 지움, 다시 보내지 않음)
    private func open(_ id: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            expanded = expanded == id ? nil : id
        }
        guard expanded == id, let opened = seen.open(id, changed: changedIDs) else { return }
        #if DEBUG
        if store.sampleMode { return }
        #endif
        let api = store.services.api
        Task { try? await api.markSeen(opened) }
    }

    private func move(_ id: UUID, to state: WorkState) {
        withAnimation(Self.move) { _ = store.move(id, to: state) }
    }

    // MARK: 삭제 · Undo

    /// 곧바로 목록에서 빼고 5초 동안 Undo. 지우지 못하면 행이 제자리로 돌아오고 알림이 뜨므로 Undo를 거둔다.
    private func delete(_ id: UUID) {
        guard let deleted = withAnimation(Self.move, { store.delete(id) }) else { return }
        withAnimation(Self.move) { undo.offer(deleted.undo) }
        deletions += 1
        Task {
            await deleted.write.value
            if undo.pending?.action.id == id, store.sections.find(id) != nil {
                withAnimation(Self.move) { undo.clear() }
            }
        }
    }

    /// Undo: 지우기 전 구역으로 곧바로 되살린다
    private func restoreDeleted() {
        withAnimation(Self.move) {
            guard let pending = undo.take() else { return }
            store.restore(pending)
        }
    }

    /// 지운 뒤 아래에 뜨는 막대: iOS 26은 유리 캡슐, 그 전은 material 캡슐 (`tfGlassCapsule`)
    @ViewBuilder
    private var undoBar: some View {
        if undo.pending != nil {
            HStack(spacing: 0) {
                Text("Deleted")
                    .foregroundStyle(TFColor.textPrimary)
                    .padding(.leading, TFSpace.lg + TFSpace.xs)
                Button(action: restoreDeleted) {
                    Text("Undo")
                        .fontWeight(.semibold)
                        .foregroundStyle(TFColor.textPrimary)
                        .padding(.leading, TFSpace.xl)
                        .padding(.trailing, TFSpace.lg + TFSpace.xs)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .font(TFFont.callout)
            .lineLimit(1)
            .fixedSize()
            .tfGlassCapsule()
            .padding(.bottom, TFSpace.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 밀어서 옮길 상태: 오른쪽으로 밀면(leading) 옆 상태, 왼쪽으로 밀면(trailing) Done
    private static func swipeStates(_ group: TaskGroup) -> (leading: WorkState?, trailing: WorkState?) {
        switch group {
        case .toDo: (.inProgress, .done)
        case .inProgress: (.toDo, .done)
        case .doneToday: (.toDo, nil)
        case .review: (nil, nil)
        }
    }

    private func swipeButton(_ id: UUID, to state: WorkState) -> some View {
        Button(state.title) { move(id, to: state) }
            .tint(swipeTint)
    }

    /// 길게 누르기 메뉴의 아이콘: 상태 표시와 같은 모양 (메뉴에는 SF Symbol만 그려진다)
    private static func symbolName(_ state: WorkState) -> String {
        switch state {
        case .toDo: "circle"
        case .inProgress: "circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    /// 밀어서 나오는 버튼: 글자가 늘 흰색이라 바탕은 두 모드 모두 어두워야 한다 (강조색은 쓰지 않는다)
    private var swipeTint: Color {
        colorScheme == .dark ? TFColor.fillSecondary : TFColor.fillInverse
    }

    @ViewBuilder
    private func expandedEvidence(for id: UUID) -> some View {
        if expanded == id {
            Group {
                if let digest = store.evidence[id] {
                    if let lead = digest.lead {
                        SourceSlip(line: lead) { openURL($0) }
                    }
                } else if store.evidenceFailed.contains(id) {
                    Text("Couldn't load the source.")
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textSecondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task { await store.loadEvidence(id) }
        }
    }

    // MARK: 연결

    @ViewBuilder
    private var reconnectBanner: some View {
        if let provider = ConnectionProvider.stageOne.first(where: {
            if case .needsReconnect = account.state(for: $0) { return true }
            return false
        }) {
            Button {
                accountRoute = .connections
            } label: {
                HStack(spacing: TFSpace.md) {
                    if let logo = provider.logo { SourceIcon(logo) }
                    Text("Reconnect to keep syncing")
                        .font(TFFont.callout)
                        .foregroundStyle(TFColor.textPrimary)
                    Spacer(minLength: TFSpace.sm)
                    Text("Reconnect")
                        .font(TFFont.callout.weight(.semibold))
                        .foregroundStyle(TFColor.textPrimary)
                }
                .padding(TFSpace.md)
                .background(TFColor.bgSurface, in: RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .plainRow(top: TFSpace.sm, bottom: TFSpace.md)
        }
    }

    /// 동의 전이면 연동 원문을 읽지 못한다: 목록 위에 한 줄 (누르면 동의 화면)
    @ViewBuilder
    private var consentBanner: some View {
        if account.shouldPromptConsent {
            Button {
                promptingConsent = true
            } label: {
                HStack(spacing: TFSpace.md) {
                    Image(systemName: "hand.raised")
                        .font(TFFont.callout.weight(.semibold))
                        .foregroundStyle(TFColor.textPrimary)
                        .frame(width: 20)
                    Text("Allow AI processing to keep your list up to date")
                        .font(TFFont.callout)
                        .foregroundStyle(TFColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Allow")
                        .font(TFFont.callout.weight(.semibold))
                        .foregroundStyle(TFColor.textPrimary)
                }
                .padding(TFSpace.md)
                .background(TFColor.bgSurface, in: RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .plainRow(top: TFSpace.sm, bottom: TFSpace.md)
        }
    }

    /// 처리방침 변경 안내 (처리방침 17장): 한 줄 + View(기기 언어의 처리방침 페이지) + 닫기. 열거나 닫으면 이 판은 다시 보이지 않는다
    @ViewBuilder
    private var policyBanner: some View {
        if let notice = account.policyNotice {
            HStack(spacing: 0) {
                Button {
                    openURL(notice.url.url())
                    account.acknowledgePolicyNotice()
                } label: {
                    HStack(spacing: TFSpace.md) {
                        Image(systemName: "doc.text")
                            .font(TFFont.callout.weight(.semibold))
                            .foregroundStyle(TFColor.textPrimary)
                            .frame(width: 20)
                        Text(notice.title(today: today))
                            .font(TFFont.callout)
                            .foregroundStyle(TFColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("View")
                            .font(TFFont.callout.weight(.semibold))
                            .foregroundStyle(TFColor.textPrimary)
                    }
                    .padding([.vertical, .leading], TFSpace.md)
                    .contentShape(Rectangle())
                }
                Button {
                    withAnimation(Self.move) { account.acknowledgePolicyNotice() }
                } label: {
                    Image(systemName: "xmark")
                        .font(TFFont.footnote.weight(.semibold))
                        .foregroundStyle(TFColor.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss")
            }
            .buttonStyle(.plain)
            .background(TFColor.bgSurface, in: RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous))
            .plainRow(top: TFSpace.sm, bottom: TFSpace.md)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if account.loaded, !account.hasConnections {
            VStack(spacing: TFSpace.lg) {
                HStack(spacing: TFSpace.sm) {
                    ForEach([SourceService.notion, .googleMeet, .gmail, .slack], id: \.self) { SourceIcon($0) }
                }
                Text("Connect your sources to start.")
                    .font(TFFont.callout)
                    .foregroundStyle(TFColor.textSecondary)
                Button("Connect") { accountRoute = .connections }
                    .buttonStyle(CapsuleButtonStyle(.primary))
                    .frame(maxWidth: 220)
            }
            .padding(TFSpace.xl)
        } else if account.loaded, account.anySyncing {
            // 첫 동기화 (몇 분 걸린다): 할 일이 들어오면 이 줄 대신 목록이 보인다
            HStack(spacing: TFSpace.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(ConnectionSync.label)
            }
            .font(TFFont.callout)
            .foregroundStyle(TFColor.textSecondary)
        } else if account.loaded {
            Text("All caught up")
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
        }
    }

    // MARK: 알림

    /// 알림 권한을 물어도 되는 때: 연결이 있고 다른 시트가 떠 있지 않음
    private var readyForPushPrompt: Bool {
        account.loaded && account.hasConnections && accountRoute == nil && !addingTask && !promptingProfile && !promptingConsent
    }

    /// 누른 알림: 떠 있는 시트를 닫고 목록을 다시 읽은 뒤 그 할 일로 (Review면 그 카드를 먼저, 할 일이면 그 행을 잠시 칠한다).
    /// 재연결 알림은 할 일이 아니라 연결 화면으로 간다.
    private func openNotification() {
        guard let target = PushCenter.shared.take() else { return }
        addingTask = false
        if target.kind == .reconnect {
            accountRoute = .connections
            return
        }
        accountRoute = nil
        Task {
            await store.load()
            guard let id = target.actionID, let found = store.sections.find(id) else { return }
            if found.group == .review {
                reviewFocus = id
            } else {
                highlighted = id
            }
            scrollTarget = id
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.6)) {
                if highlighted == id { highlighted = nil }
            }
        }
    }

    // MARK: 첫 실행

    /// 기존 사용자도 모두 동의 없이 시작한다. 연결이 있으면 로그인 뒤 한 번 묻는다 (이름을 묻는 중이면 그 뒤에).
    private func promptConsentIfNeeded() {
        guard !consentPrompted, !promptingProfile, account.shouldPromptConsent else { return }
        consentPrompted = true
        promptingConsent = true
    }

    /// 원문 속 "나"를 알아보려면 이름이 필요하다. 비어 있으면 처음 한 번 묻는다.
    private func promptProfileIfNeeded() {
        let key = "profilePrompted.\(userID.uuidString.lowercased())"
        guard let profile = account.profile, profile.displayName == nil, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        promptingProfile = true
    }
}

/// 주간 질문 (PRD 지표 5). 작게, 목록 아래에.
private struct WeeklyCheckCard: View {
    let onAnswer: (WeeklyCheckAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.md) {
            Text("Tracking anything outside Taskforce this week?")
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TFSpace.sm) {
                Button("Yes") { onAnswer(.yes) }
                Button("No") { onAnswer(.no) }
                Spacer()
                Button("Skip") { onAnswer(.skipped) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(TFColor.textSecondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(TFSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgSurface, in: RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous))
    }
}

private extension View {
    /// 구분선 · 배경 없는 행 (머리 · 카드)
    func plainRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: TFSpace.lg, bottom: bottom, trailing: TFSpace.lg))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
#endif
