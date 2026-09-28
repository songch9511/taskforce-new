#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// iPhone 한 화면 (Figma 9:529 · Website 17:962): "Review 1 / N" + 카드 한 장 → "Now" + Task row 목록.
/// 순서는 서버가 정한 그대로 보여 준다. 행을 누르면 근거 한 줄만 펼친다.
struct HomeView: View {
    let userID: UUID
    let email: String?

    @Environment(NowStore.self) private var store
    @Environment(AccountStore.self) private var account
    @Environment(ActionChangeFeed.self) private var changes
    @Environment(\.openURL) private var openURL
    @State private var expanded: UUID?
    @State private var accountRoute: AccountRoute?
    @State private var addingTask = false
    /// 직접 추가가 끝날 때마다 늘린다 (가벼운 햅틱)
    @State private var addedTasks = 0
    @State private var promptingProfile = false
    /// 동의 전인데 연결이 있으면 로그인 뒤 한 번 (목록은 그대로 보인다)
    @State private var promptingConsent = false
    @State private var consentPrompted = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            content
                .background(TFColor.bgCanvas)
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
        .task {
            await account.load()
            promptProfileIfNeeded()
            promptConsentIfNeeded()
        }
        .sheet(item: $accountRoute) { route in
            AccountSheet(email: email, initialRoute: route)
        }
        .sheet(isPresented: $addingTask) {
            NewTaskSheet { addedTasks += 1 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: addedTasks)
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
            list
                .overlay {
                    if isEmpty { emptyState }
                }
        }
    }

    private var isEmpty: Bool {
        store.tasks.isEmpty && store.confirmations.isEmpty && store.response?.weeklyCheck == nil
    }

    private var today: LocalDate { DueDateFormat.today() }

    private var list: some View {
        List {
            if let error = store.loadError {
                Text(error)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .plainRow(top: 0, bottom: TFSpace.md)
            }
            reconnectBanner
            consentBanner
            if let first = store.confirmations.first {
                reviewHeader(count: store.confirmations.count)
                reviewCard(first)
            }
            if !store.tasks.isEmpty {
                Text("Now")
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                    .plainRow(top: store.confirmations.isEmpty ? TFSpace.sm : 0, bottom: TFSpace.md)
                ForEach(Array(store.tasks.enumerated()), id: \.element.id) { index, ranked in
                    taskRow(ranked)
                        .listRowInsets(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: 0, trailing: 0))
                        .listRowBackground(TFColor.bgCanvas)
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

    // MARK: Now

    private func taskRow(_ ranked: RankedAction) -> some View {
        let action = ranked.action
        let done = store.completed.contains(action.id)
        let state: TaskRowState = done ? .done : (action.dueDate.map { DueText.isOverdue($0, today: today) } == true ? .overdue : .open)
        return TaskRow(
            title: action.title,
            meta: TaskMetaLine(due: action.dueDate.map { DueText.short($0, today: today) }, counterpart: action.counterpart),
            state: state,
            onToggle: {
                guard !store.busy.contains(action.id) else { return }
                Task {
                    if done { await store.reopen(action.id) } else { await store.complete(action.id) }
                }
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
        } else if account.loaded {
            Text("All caught up")
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
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
