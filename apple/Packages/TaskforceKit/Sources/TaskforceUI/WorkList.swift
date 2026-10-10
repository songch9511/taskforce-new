import SwiftUI
import TaskforceKit

/// WorkList (0.2.0 디자인 시스템 Organisms): All work. 프로젝트 묶음 → Ungrouped → 조용한 Done today, 함께 걸리는 검색 · 필터.
/// - 도구 줄은 검색칸 하나. 필터는 칸 끝 `list-filter` 아이콘 뒤에 있고, 열면 그 자리에 Project · Status ChoiceChips 카드.
///   닫혀 있을 때 고른 필터는 한 줄("Shape launch · Waiting") + Clear
/// - 묶음 이름에 개수가 없다. 고정한 일(셋까지)이 그 묶음 앞. 활동이 바뀌어도 줄 순서는 그대로 (`WorkListLayout`)
/// - 빈 화면은 서로 다르다 (`WorkLoad`, `PanelEmptyState.Kind`): 목록 없음(읽는 중이면 아무것도 보이지 않는다) · 오프라인 · 읽기 실패 ·
///   할 일 없음 · 맞는 일 없음. 받은 목록 뒤에 끊기거나 실패하면 목록은 두고 위에 Notice 하나
/// - 검색어 · 필터 · 열린 필터 · 고정은 쓰는 쪽(셸 모델)이 가진다: 계정이 바뀌거나 레일의 All work로 열면 거기서 비운다
public struct WorkList: View {
    let items: [WorkItem]
    let load: WorkLoad
    @Binding var filter: WorkFilter
    @Binding var filtersOpen: Bool
    let pins: WorkPins
    let currentID: UUID?
    let highlightedID: UUID?
    let today: LocalDate
    let onOpen: (UUID) -> Void
    let onPin: (UUID) -> Void
    let onUnpin: (UUID) -> Void
    let onAddTask: () -> Void
    let onConnect: (() -> Void)?
    let onRetry: () -> Void
    @State private var hovered: UUID?
    @Environment(\.colorSchemeContrast) private var contrast

    /// - items: 모든 줄(필터 전, `WorkItem.list`), today: 기한 글자의 오늘 (`DueDateFormat.today()`)
    /// - onConnect: 있으면 할 일 없음 화면에 Connect a source (연결된 원문이 없을 때)
    public init(
        items: [WorkItem], load: WorkLoad, filter: Binding<WorkFilter>, filtersOpen: Binding<Bool>, pins: WorkPins,
        currentID: UUID? = nil, highlightedID: UUID? = nil, today: LocalDate,
        onOpen: @escaping (UUID) -> Void = { _ in }, onPin: @escaping (UUID) -> Void = { _ in }, onUnpin: @escaping (UUID) -> Void = { _ in },
        onAddTask: @escaping () -> Void = {}, onConnect: (() -> Void)? = nil, onRetry: @escaping () -> Void = {}
    ) {
        self.items = items
        self.load = load
        _filter = filter
        _filtersOpen = filtersOpen
        self.pins = pins
        self.currentID = currentID
        self.highlightedID = highlightedID
        self.today = today
        self.onOpen = onOpen
        self.onPin = onPin
        self.onUnpin = onUnpin
        self.onAddTask = onAddTask
        self.onConnect = onConnect
        self.onRetry = onRetry
    }

    /// 검색칸 (라벨은 VoiceOver에만)
    nonisolated public static let searchLabel = "Search work"
    nonisolated public static let searchPrompt = "Search work…"

    /// 필터 버튼의 접근성 이름: 고른 필터가 있으면 "Filters: Shape launch, Waiting"
    nonisolated public static func filtersLabel(_ filter: WorkFilter) -> String {
        filter.activeLabels.isEmpty ? "Filters" : "Filters: \(filter.activeLabels.joined(separator: ", "))"
    }

    public var body: some View {
        switch load {
        case .loading:
            // 이번 실행의 목록이 아직 없다: 할 일이 없다고 말하지 않는다
            Color.clear.frame(height: 0)
        case .offline:
            PanelEmptyState(.offline) { tryAgain(.md) }
        case .failed:
            PanelEmptyState(.couldNotLoad) { tryAgain(.md) }
        case .loaded(let problem):
            loaded(problem)
        }
    }

    private func tryAgain(_ size: TFButtonStyle.Size) -> some View {
        Button("Try again", action: onRetry).buttonStyle(TFButtonStyle(.secondary, size: size))
    }

    @ViewBuilder
    private func loaded(_ problem: WorkLoad.Problem?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem {
                // 패널의 Notice는 제목과 동작만 (설명은 Settings에만)
                Notice(title: problem == .offline ? PanelEmptyKind.offline.title : PanelEmptyKind.couldNotLoad.title) {
                    tryAgain(.sm)
                }
                .padding(.bottom, TFSpace.md)
            }
            if items.isEmpty {
                PanelEmptyState(.noWork) {
                    Button("Add task", action: onAddTask).buttonStyle(TFButtonStyle(.primary, size: .md))
                    if let onConnect {
                        Button("Connect a source", action: onConnect).buttonStyle(TFButtonStyle(.secondary, size: .md))
                    }
                }
            } else {
                list
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        TFSearchField(Self.searchLabel, prompt: Self.searchPrompt, text: $filter.query) {
            TFIconButton(.filters, label: Self.filtersLabel(filter), isOn: filtersOpen) { filtersOpen.toggle() }
        }
        if filtersOpen {
            Card {
                ChoiceChips(
                    "Project", options: WorkListLayout.projectOptions(items).map { .init($0, label: $0.title) }, selection: filter.project
                ) { filter.project = $0 }
                ChoiceChips(
                    "Status", options: WorkStatusFilter.allCases.map { .init($0, label: $0.title) }, selection: filter.status, continued: true
                ) { filter.status = $0 }
            }
            .padding(.top, TFSpace.sm)
        } else if filter.hasActiveFilters {
            HStack(spacing: TFSpace.xs) {
                Text(filter.activeLabels.joined(separator: " · "))
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Clear") { filter.clearFilters() }
                    .buttonStyle(TFButtonStyle(.text))
            }
            .padding(.leading, TFSpace.sm)
            .padding(.top, 6)
        }
        let groups = WorkListLayout.groups(items, filter: filter, pinned: pins.shown(in: items))
        if groups.isEmpty {
            PanelEmptyState(.noMatch) {
                Button("Clear filters") {
                    filter = WorkFilter()
                }
                .buttonStyle(TFButtonStyle(.text, size: .md))
            }
        }
        ForEach(groups) { group in
            section(group)
        }
    }

    private func section(_ group: WorkListGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title)
                .font(TFFont.caption)
                .foregroundStyle(TFColor.textSecondary)
                .padding(EdgeInsets(top: 18, leading: TFSpace.sm, bottom: TFSpace.xs, trailing: TFSpace.sm))
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .overlay(alignment: .top) {
                        // 줄 사이 머리선은 글자에서 시작한다. 호버 · 고른 줄의 위아래에서는 숨긴다
                        if index > 0, !isLit(item.id), !isLit(group.items[index - 1].id) {
                            Rectangle()
                                .fill(contrast == .increased ? TFColor.borderControl : TFColor.borderDefault)
                                .frame(height: 1)
                                .padding(.leading, 36)
                                .padding(.trailing, TFSpace.sm)
                        }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }

    private func isLit(_ id: UUID) -> Bool {
        id == currentID || id == highlightedID || id == hovered
    }

    private func row(_ item: WorkItem) -> some View {
        let done = item.state == .done
        let due = item.action.dueDate.map { DueText.short($0, today: today) }
        let overdue = !done && item.action.dueDate.map { DueText.isOverdue($0, today: today) } == true
        let urgent = !done && item.action.dueDate != nil && DueText.isUrgent(due: item.action.dueDate, reasons: item.reasons, today: today)
        let pinned = pins.isPinned(item.id)
        let canPin = pins.canPin(item.id, known: Set(items.map(\.id)))
        return Button { onOpen(item.id) } label: {
            WorkRow(
                title: item.action.title, state: TaskStatusMark.State(item.state), performer: item.performer, activity: item.activity,
                due: due, urgent: urgent, overdue: overdue, pinned: pinned, current: item.id == currentID,
                highlighted: item.id == highlightedID || item.id == hovered
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovered)
        .contextMenu {
            if pinned {
                Button("Unpin work") { onUnpin(item.id) }
            } else {
                Button("Pin work") { onPin(item.id) }.disabled(!canPin)
            }
        }
        .accessibilityAction(named: pinned ? "Unpin work" : "Pin work") {
            if pinned { onUnpin(item.id) } else if canPin { onPin(item.id) }
        }
    }
}

#Preview("Work list") {
    @Previewable @State var filter = WorkFilter()
    @Previewable @State var open = false
    let action = { (n: Int, title: String, started: Bool) in
        ActionSummary(
            id: UUID(), title: title, owner: .me, status: .open, dueDate: n == 2 ? DueDateFormat.today() : nil, counterpart: nil,
            needsConfirmation: false, confirmReasons: [], startedAt: started ? Date() : nil, lastActivityAt: Date()
        )
    }
    let items = WorkItem.list(
        reviews: [action(1, "Launch timing", true)], open: [action(2, "Pricing page", true), action(3, "Onboarding copy", false)], doneToday: []
    )
    ScrollView {
        WorkList(items: items, load: .loaded(problem: nil), filter: $filter, filtersOpen: $open, pins: WorkPins(), today: DueDateFormat.today())
            .padding(16)
    }
    .frame(width: 380, height: 480)
    .background(TFColor.bgPanel)
}
