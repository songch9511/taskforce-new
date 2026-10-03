#if os(macOS)
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 목록 칸 (Figma M1 `List viewport`, 폭 300 · settings/sidebar): 맨 위 안내 줄(Allow AI · 처리방침 · 실패 원문) → 섹션(머리 고정, `Review 4`)
/// → 접힌 나머지 `Show 2 More ⌄` → Done Today 접힌 한 줄. 행은 `MacListRow`(상태 표시 없음, 제목 + 기한 + 바뀜 점).
/// 많은 행도 끊기지 않게 `LazyVStack` + 고정 머리, 넘치면 아래 흐림.
struct LauncherListPane: View {
    @Bindable var model: LauncherModel

    /// 아래에 더 있는지 (아래 흐림)
    @State private var hasMoreBelow = false
    /// 직전에 고른 줄 (한 칸 위로 옮길 때 고정 머리에 가리지 않게 한 줄 더 보인다)
    @State private var lastSelection = 0

    var body: some View {
        let sections = model.sections
        let offsets = Self.offsets(sections)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 0).id(Self.top)
                    if model.showsSyncing {
                        Text(ConnectionSync.label)
                            .font(TFFont.meta)
                            .foregroundStyle(TFColor.textSecondary)
                            .padding(.horizontal, 18)
                            .frame(height: 28, alignment: .leading)
                    }
                    ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                        Section {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { itemIndex, item in
                                let index = offsets[sectionIndex] + itemIndex
                                row(item, selected: index == model.selection)
                                    .padding(.horizontal, TFSpace.sm)
                                    .id(index)
                                    .onTapGesture { tap(item, at: index) }
                            }
                        } header: {
                            if let title = section.title {
                                SectionHeader(title, count: section.count ?? section.items.count)
                                    .padding(.horizontal, TFSpace.sm)
                                    .background(TFColor.settingsSidebar)
                            }
                        }
                    }
                }
                .padding(.top, TFSpace.xs)
                .padding(.bottom, TFSpace.sm)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
            } action: { _, more in
                hasMoreBelow = more
            }
            .onChange(of: model.selection) { old, index in
                lastSelection = old
                guard model.screen == .list else { return }
                withAnimation(.easeOut(duration: 0.1)) { scroll(proxy, to: index, from: old) }
            }
        }
        .background(TFColor.settingsSidebar)
        .scrollEdgeFade(TFColor.settingsSidebar, isActive: hasMoreBelow)
    }

    private static let top = "list-top"

    /// 고른 줄이 보이게: 한 칸 아래면 그 줄까지, 한 칸 위면 그 위 줄까지(고정 머리 30이 행 36을 가리지 않게), 맨 위 줄이면 맨 위, 멀리 뛰면 가운데
    private func scroll(_ proxy: ScrollViewProxy, to index: Int, from old: Int) {
        if index <= 0 {
            proxy.scrollTo(Self.top, anchor: .top)
        } else if index == old - 1 {
            proxy.scrollTo(index - 1)
        } else if index == old + 1 {
            proxy.scrollTo(index)
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private static func offsets(_ sections: [LauncherSection]) -> [Int] {
        var running = 0
        return sections.map { section in
            defer { running += section.items.count }
            return running
        }
    }

    /// 할 일 · 저장본 행은 고르기만 한다 (상세가 바로 보인다, ↩가 원문 · ⌘K). Show N More · Done Today는 그 줄의 Button이 실행한다
    /// (바깥 탭과 함께 불려 두 번 열고 닫히지 않게). 나머지 줄(안내 · 명령 등)은 실행
    private func tap(_ item: LauncherItem, at index: Int) {
        if model.screen != .list { model.back() }
        model.select(index)
        switch item {
        case .review, .task, .done, .saved, .showMore, .doneToday: break
        default: model.run(item)
        }
    }

    private var today: LocalDate { DueDateFormat.today() }

    /// 상세로 포커스를 옮겨도(Tab · →) 목록에서 고른 행은 그대로 보인다
    @ViewBuilder
    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        switch item {
        case .review(let action):
            MacListRow(
                title: action.title,
                accessory: action.dueDate.map { DueText.accessory($0, today: today) },
                urgent: DueText.isUrgent(due: action.dueDate, reasons: [], today: today),
                changed: model.showsDot(action.id),
                selected: selected
            )
        case .task(let ranked):
            MacListRow(
                title: ranked.action.title,
                accessory: ranked.action.dueDate.map { DueText.accessory($0, today: today) },
                urgent: DueText.isUrgent(due: ranked.action.dueDate, reasons: ranked.reasons, today: today),
                changed: model.showsDot(ranked.action.id),
                selected: selected
            )
        case .done(let action):
            // 끝낸 할 일은 기한을 보이지 않는다 (지남 · 오늘 빨강이 뜻이 없다)
            MacListRow(title: action.title, selected: selected, dimmed: true)
        case .saved(let row):
            let done = row.task.status == .doneToday
            MacListRow(
                title: row.task.title,
                accessory: done ? nil : row.task.dueDate.map { DueText.accessory($0, today: today) },
                urgent: !done && DueText.isUrgent(due: row.task.dueDate, reasons: [], today: today),
                selected: selected,
                dimmed: done
            )
        case .showMore(let group, let hidden):
            ShowMoreRow(count: hidden, section: group.title, selected: selected) { model.run(item) }
        case .doneToday(let count, let expanded):
            SectionHeader(TaskGroup.doneToday.title, count: count, disclosure: expanded ? .expanded : .collapsed, selected: selected) {
                model.run(item)
            }
        case .failedSources(let failed):
            MacListRow(title: Self.failedTitle(failed), accessory: failed.latestAt.map { WhenText.label($0) }, selected: selected)
        case .policyNotice(let notice):
            MacListRow(title: notice.title(today: today), accessory: "View", selected: selected)
        case .allowAI:
            MacListRow(title: "Allow AI processing to keep your list up to date", selected: selected)
        case .command(let command):
            MacListRow(title: command.title, selected: selected)
        case .ask(let question):
            MacListRow(title: "Ask “\(LauncherFlowView.oneLine(question))”", selected: selected)
        case .handoff(let action):
            MacListRow(title: "Hand off “\(action.title)” to AI", selected: selected)
        case .sendAsSource(let text):
            MacListRow(title: "Send as source", accessory: LauncherFlowView.oneLine(text), selected: selected)
        case .addAction(let title):
            MacListRow(title: "Add “\(title)”", selected: selected)
        case .signIn, .signInWithGoogle, .signInWithEmail:
            // 로그아웃 목록은 한 열 (`LauncherFlowView`)
            EmptyView()
        }
    }

    /// 실패 원문 줄 (Figma에 없음 · 후보): "Couldn’t read 2 sources"
    static func failedTitle(_ failed: FailedSources) -> String {
        failed.count == 1 ? "Couldn’t read 1 source" : "Couldn’t read \(failed.count) sources"
    }
}
#endif
