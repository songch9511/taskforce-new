#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// iPhone 한 화면 (Figma 9:529 · Website 17:962): "Review 1 / N" + 카드 한 장 → In Progress · To Do · Done Today의 Task row 목록.
/// 순서는 서버가 정한 그대로 보여 준다 (구역 나누기는 `TaskBoard`). 행을 누르면 근거 한 줄만 펼친다.
/// 상태는 To Do · In Progress · Done 세 이름으로만 옮긴다 (`NowStore.move`):
/// - 왼쪽 상태 표시: ○ · ● → Done, ✓ → 끝내기 전 상태
/// - 밀기: To Do는 오른쪽 In Progress · 왼쪽 Done, In Progress는 오른쪽 To Do · 왼쪽 Done, Done Today는 오른쪽 To Do
/// - 길게 누르기: 세 상태 (지금 상태에 체크)
/// 삭제: 왼쪽으로 밀기(Done 옆, 끝까지 밀면 Done) · 길게 누르기 맨 아래. 지운 뒤 5초 동안 아래에 "Deleted  Undo" (`NowStore.delete` · `restore`)
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

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            content
                .background(TFColor.bgCanvas)
                .overlay(alignment: .bottom) { undoBar }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            addingTask = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New Task")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            accountRoute = .home
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .accessibilityLabel("Account")
                    }
                }
        }
        // 나타날 때마다, 그리고 Realtime 신호가 올 때마다
        .task(id: changes.revision) { await store.load() }
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
        if !store.loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.response == nil, let error = store.loadError {
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
            ScrollViewReader { proxy in
                list
                    .overlay {
                        if isEmpty { emptyState }
                    }
                    // 누른 알림의 할 일로
                    .onChange(of: scrollTarget) { _, id in
                        guard let id else { return }
                        scrollTarget = nil
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
            }
        }
    }

    private var isEmpty: Bool {
        store.sections.isEmpty && store.response?.weeklyCheck == nil
    }

    private var today: LocalDate { DueDateFormat.today() }

    private var list: some View {
        let sections = store.sections
        // 비어 있지 않은 구역 (Review 카드 아래로)
        let groups = [TaskGroup.inProgress, .toDo, .doneToday].filter { !sections.actions(in: $0).isEmpty }
        return List {
            if let error = store.loadError {
                Text(error)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .plainRow(top: 0, bottom: TFSpace.md)
            }
            reconnectBanner
            consentBanner
            policyBanner
            // 누른 알림의 확인 요청이면 그 카드를 먼저
            if let first = sections.review.first(where: { $0.id == reviewFocus }) ?? sections.review.first {
                reviewHeader(count: sections.review.count)
                reviewCard(first)
            }
            ForEach(groups, id: \.self) { group in
                Text(group.title)
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                    .plainRow(top: group == groups.first ? (sections.review.isEmpty ? TFSpace.sm : 0) : TFSpace.xl, bottom: TFSpace.md)
                ForEach(Array(sections.actions(in: group).enumerated()), id: \.element.id) { index, action in
                    taskRow(action, group: group)
                        .id(action.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: 0, trailing: 0))
                        .listRowBackground(highlighted == action.id ? TFColor.bgSurface : TFColor.bgCanvas)
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
        .environment(\.defaultMinListRowHeight, 0)
        .refreshable {
            await store.load()
            await account.reloadConnections()
        }
    }

    // MARK: Review

    private func reviewHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Review")
                .font(TFFont.headline)
                .foregroundStyle(TFColor.textPrimary)
            Spacer()
            Text("1 / \(count)")
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
        }
        .plainRow(top: TFSpace.sm, bottom: TFSpace.md)
    }

    private func reviewCard(_ action: ActionSummary) -> some View {
        ReviewCard(
            title: action.title,
            value: action.dueDate.map { DueText.short($0, today: today) },
            busy: store.busy.contains(action.id),
            onConfirm: { Task { await store.confirm(action.id) } },
            onDismiss: { Task { await store.dismiss(action.id) } }
        ) {
            if let digest = store.evidence[action.id], let lead = digest.lead {
                EvidenceView(lead, others: digest.otherSources, quoteLineLimit: 3, onOpen: open(lead))
            }
        }
        .id(action.id)
        .task(id: action.id) { await store.loadEvidence(action.id) }
        .plainRow(top: 0, bottom: TFSpace.xl + TFSpace.xs)
    }

    // MARK: In Progress · To Do · Done Today

    /// 행이 다른 구역으로 옮겨 갈 때 · 지울 때 · Undo 막대
    private static let move = Animation.snappy(duration: 0.25)

    private func taskRow(_ action: ActionSummary, group: TaskGroup) -> some View {
        let done = group == .doneToday
        let overdue = action.dueDate.map { DueText.isOverdue($0, today: today) } == true
        let state: TaskRowState = done ? .done : (overdue ? .overdue : .open)
        return TaskRow(
            title: action.title,
            meta: TaskMetaLine(due: action.dueDate.map { DueText.short($0, today: today) }, counterpart: action.counterpart),
            state: state,
            inProgress: group == .inProgress,
            onToggle: {
                // ○ · ●는 Done Today로, ✓는 끝내기 전 구역으로 옮겨 간다
                withAnimation(Self.move) { _ = store.toggle(action.id) }
            }
        ) {
            expandedEvidence(for: action.id)
        }
        .padding(.trailing, TFSpace.lg)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) {
                expanded = expanded == action.id ? nil : action.id
            }
        }
        .accessibilityAction(named: expanded == action.id ? "Hide source" : "Show source") {
            expanded = expanded == action.id ? nil : action.id
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let state = Self.swipeStates(group).leading { swipeButton(action.id, to: state) }
        }
        // 끝까지 밀면 Done (첫 버튼). Done이 없는 Done Today는 끝까지 밀어도 지우지 않는다
        .swipeActions(edge: .trailing, allowsFullSwipe: Self.swipeStates(group).trailing != nil) {
            if let state = Self.swipeStates(group).trailing { swipeButton(action.id, to: state) }
            if group.isDeletable {
                Button("Delete", role: .destructive) { delete(action.id) }
            }
        }
        .contextMenu {
            if let current = WorkState(group) {
                Picker("Status", selection: Binding(get: { current }, set: { move(action.id, to: $0) })) {
                    ForEach(WorkState.allCases, id: \.self) { state in
                        Label(state.title, systemImage: Self.symbolName(state)).tag(state)
                    }
                }
                .pickerStyle(.inline)
            }
            if group.isDeletable {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { delete(action.id) }
            }
        }
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
                        EvidenceView(lead, others: digest.otherSources, quoteLineLimit: 3, onOpen: open(lead))
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
            .padding(.top, TFSpace.sm)
            .task { await store.loadEvidence(id) }
        }
    }

    private func open(_ line: EvidenceLine) -> (() -> Void)? {
        guard let url = line.externalURL else { return nil }
        return { openURL(url) }
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
