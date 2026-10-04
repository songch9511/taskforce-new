#if os(iOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// iPhone 할 일 상세 셸 (Figma 156:6 P2 190:3454 · 멈춘 뒤 P9 291:2879). 실행을 쓸 수 있는 계정(`GET /credits` 200)에서만 연다 (`PhoneHome.rowTap`).
/// 제목 전부 · 기한 → **Taskforce 갈래**(`LaneCard`, `View Draft`는 문장 아래) → `Source` + `Show All N ›` + 원문 슬립 → 아래 `Mark Done`. 오른쪽 위 `···`:
/// `Stop Taskforce`(끝나지 않은 run이 있을 때) · `Open in <서비스>`. iPhone은 run을 시작하지 않는다 (`Run with AI…` 없음, `RunAvailability.canStart`).
/// 갈래 글은 `RunLaneText`(멈춘 시각 = 서버 `stopped_at`), `Resume Taskforce`는 숨긴다 (서버에 재개 없음, U6a).
/// `Waiting on` 갈래 · 원문 전체(M3b)는 U5, 하단 막대 큰 글자 규칙(P4 · P11)은 U9 — 여기는 셸만.
/// 보이는 동안 그 할 일의 run을 지켜본다 (`RunStore.watch`, 앞에 있을 때만 · 움직이는 run이 있을 때만 다시 읽는다).
struct TaskDetailView: View {
    let actionID: UUID
    /// 오프라인이거나 저장본이면 Mark Done · Stop을 보내지 않는다 (`PhoneHome.canWrite`)
    let canWrite: Bool
    /// `Mark Done`(끝낸 할 일이면 끝내기 전 상태로). 옮기기 · 멈추기는 목록이 한다
    let onToggle: () -> Void
    let onOpenDraft: (Artifact) -> Void
    let onShowAllSources: () -> Void

    @Environment(NowStore.self) private var store
    @Environment(RunStore.self) private var runs
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// Mark Done을 누를 때마다 (가벼운 햅틱)
    @State private var toggles = 0

    var body: some View {
        let found = store.sections.find(actionID)
        ScrollView {
            if let found {
                VStack(alignment: .leading, spacing: 22) {
                    header(found.action, done: found.group == .doneToday)
                    lane
                    sources
                }
                .padding(.horizontal, TFSpace.lg)
                .padding(.top, 10)
                .padding(.bottom, TFSpace.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(TFColor.bgCanvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasMenuItems {
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
        }
        // 아래 Mark Done 막대: 글자가 커져도 내용이 막대 위에서 끝나게 막대 높이만큼 스크롤 영역을 줄인다 (Figma는 Content 아래 110 고정)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let found { markDoneBar(done: found.group == .doneToday) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: toggles)
        .task { await store.loadEvidence(actionID) }
        // 앞에 있는 동안만 지켜본다 (뒤로 가거나 초안 화면을 밀면 멈춘다)
        .onAppear { runs.watch(scenePhase == .active ? [actionID] : []) }
        .onDisappear { runs.watch([]) }
        .onChange(of: scenePhase) { _, phase in runs.watch(phase == .active ? [actionID] : []) }
        // 지켜보던 run이 초안을 내면 VoiceOver로 알린다 (처음 읽은 값은 알리지 않는다)
        .onChange(of: runs.lane(for: actionID).state) { old, new in
            if new == .draftReady, old != .draftReady, old != .none {
                AccessibilityNotification.Announcement(RunLaneText.draftAnnouncement).post()
            }
        }
        // 다른 기기에서 지우거나 확정 요청을 넘겨 목록에서 사라지면 목록으로 돌아간다
        .onChange(of: found == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    // MARK: 머리

    /// 제목 전부(28 semibold, 자르지 않음) + 기한 (지났거나 오늘이면 status/overdue, 목록 행과 같은 기준)
    private func header(_ action: ActionSummary, done: Bool) -> some View {
        let today = DueDateFormat.today()
        return VStack(alignment: .leading, spacing: TFSpace.sm) {
            Text(action.title)
                .font(.title.weight(.semibold))
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let due = action.dueDate {
                let text = DueText.short(due, today: today)
                Text(text)
                    .font(TFFont.callout)
                    .foregroundStyle(!done && DueText.isUrgent(due: due, reasons: [], today: today) ? TFColor.statusOverdue : TFColor.textSecondary)
                    // "Due, Sat" (보이는 글자와 같은 값 + 이름: 이름만 바꾸면 접근성 감사가 글자가 잘렸다고 본다)
                    .accessibilityLabel("Due")
                    .accessibilityValue(text)
            }
        }
    }

    // MARK: Taskforce 갈래

    @ViewBuilder
    private var lane: some View {
        if let text = RunLaneText.make(runs.lane(for: actionID)) {
            LaneCard(
                heading: "Taskforce", title: text.title, subtitle: text.subtitle, spokenState: text.spokenState,
                action: text.draft.map { draft in LaneCard.Action(RunLaneText.viewDraft) { onOpenDraft(draft) } }
            )
        }
    }

    // MARK: 원문

    /// `Source` + `Show All N ›`(원문 줄이 둘 이상일 때) + 가장 최근 근거의 슬립
    @ViewBuilder
    private var sources: some View {
        if let digest = store.evidence[actionID] {
            if let lead = digest.lead {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: TFSpace.xs) {
                        Text("Source")
                            .font(TFFont.calloutEmphasis)
                            .foregroundStyle(TFColor.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if digest.lines.count > 1 {
                            Button(action: onShowAllSources) {
                                HStack(spacing: TFSpace.xs) {
                                    Text("Show All \(digest.lines.count)")
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
                    SourceSlip(line: lead) { openURL($0) }
                }
            }
        } else if store.evidenceFailed.contains(actionID) {
            Text("Couldn't load the source.")
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textSecondary)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: ··· · Mark Done

    private var openLink: EvidenceLine? { store.evidence[actionID]?.openLink }
    private var hasOpenRun: Bool { !runs.stopTargets(for: actionID).isEmpty }
    private var hasMenuItems: Bool { hasOpenRun || openLink?.externalURL != nil }

    /// `···`: Stop Taskforce · Open in <서비스>. `Run with AI…`는 없다 (iPhone은 시작하지 않는다)
    private var moreMenu: some View {
        Menu {
            if hasOpenRun {
                Button("Stop Taskforce", systemImage: "stop.circle", role: .destructive) { stop() }
                    .disabled(!canWrite || runs.stopping.contains(actionID))
            }
            if let link = openLink, let url = link.externalURL {
                Button(link.service.openTitle, systemImage: "arrow.up.right.square") { openURL(url) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// 그 할 일의 끝나지 않은 run을 모두 멈춘다 (확인 대화 없음: 다음 단계만 막아 되돌릴 일이 없다). 보냈으면 VoiceOver로 알린다
    private func stop() {
        Task {
            if await runs.stop(actionID: actionID) {
                AccessibilityNotification.Announcement(RunLaneText.stopAnnouncement).post()
            }
        }
    }

    /// 아래 떠 있는 유리 캡슐 (Figma Toolbar): 열린 할 일은 `Mark Done`, 오늘 끝낸 할 일은 `Mark <끝내기 전 상태>`
    private func markDoneBar(done: Bool) -> some View {
        let title = done ? "Mark \((store.toggleTarget(actionID) ?? .toDo).title)" : "Mark Done"
        return Button {
            toggles += 1
            onToggle()
        } label: {
            Text(title)
                .font(TFFont.body)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(6)
        .tfGlassCapsule()
        .disabled(!canWrite)
        .opacity(canWrite ? 1 : 0.4)
        .padding(.bottom, TFSpace.sm)
    }
}

/// `Show All N`: 그 할 일의 원문 슬립 전부 (최근 것이 위). 원문 전체 · 묶음 보기(M3b)는 U5
struct TaskSourcesView: View {
    let actionID: UUID

    @Environment(NowStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        let lines = Array((store.evidence[actionID]?.lines ?? []).reversed())
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TFSpace.md) {
                ForEach(lines) { line in
                    SourceSlip(line: line) { openURL($0) }
                }
            }
            .padding(.horizontal, TFSpace.lg)
            .padding(.vertical, TFSpace.sm)
        }
        .background(TFColor.bgCanvas)
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
