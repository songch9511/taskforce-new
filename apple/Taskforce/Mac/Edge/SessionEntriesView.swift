#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 두 세션 패널이 같이 그리는 본문의 줄들 (DZ oa-session-view-dz v2): `SessionTimeline`이 정한 순서 그대로 — 말 · 단계 줄 · 접힌 묶음 · 답 밑 줄 · 도는 중 시계.
/// 말(사용자 · 어시스턴트 · 이벤트)은 쓰는 쪽이 그린다 (`item`): Claude 패널은 읽기 전용 말풍선, Taskforce 패널은 전달 줄 · View full이 붙은 줄.
/// 간격은 4/8 격자다: 블록 사이 12, 답 밑 줄은 답 바로 밑 4. 열린 묶음의 머리는 패널 본문 위에 붙는다 (DZ E3 "머리 붙임": 61줄을 스크롤해도 어느 묶음인지 보인다)
struct SessionEntriesView<Item: View>: View {
    let entries: [SessionEntry]
    let steps: [String: SessionStepInfo]
    @Bindable var state: SessionStepsState
    /// 단계 줄의 Input · Result를 읽는다 (줄 id → 본문). 읽을 수 없으면 nil
    var loadDetail: (String) async -> ClaudeAppToolDetail? = { _ in nil }
    /// 말 · 이벤트 한 줄 (입력 줄의 id)
    @ViewBuilder var item: (String) -> Item
    /// 답 밑 줄에 시간을 보이나 (Assistant 창은 복사만)
    var showsTime = true

    /// 항목 위 간격 (4/8 격자): 첫 항목은 0, 답 밑 줄 · 시계 줄은 바로 밑 4, 나머지는 블록 사이 12
    static func gap(before entry: SessionEntry, at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch entry {
        case .footer, .clock: return TFSpace.xs
        case .item, .steps: return TFSpace.md
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                entryView(entry, index: index)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: SessionEntry, index: Int) -> some View {
        let gap = Self.gap(before: entry, at: index)
        switch entry {
        case .item(let id):
            item(id)
                .padding(.top, gap)
                .onHover { inside in
                    // 이 답 밑에 줄이 있으면 답 위 호버가 줄의 복사 아이콘을 드러낸다
                    guard case .footer(let footer)? = index + 1 < entries.count ? entries[index + 1] : nil, footer.id == "footer-\(id)" else { return }
                    if inside { state.hoveredFooter = footer.id } else if state.hoveredFooter == footer.id { state.hoveredFooter = nil }
                }
        case .steps(let run):
            if run.isGroup, state.isOpen(run) {
                // 열린 묶음은 머리가 붙는 `Section`이다: 위 간격을 `padding`으로 주면 머리와 본문 각각에 붙어 머리가 12 내려앉고 본문이 12 벌어진다. 따로 한 칸을 둔다
                Color.clear.frame(height: gap)
                stepsView(run)
            } else {
                stepsView(run).padding(.top, gap)
            }
        case .footer(let footer):
            SessionFooterView(footer: footer, revealed: state.hoveredFooter == footer.id, showsTime: showsTime) { inside in
                if inside { state.hoveredFooter = footer.id } else if state.hoveredFooter == footer.id { state.hoveredFooter = nil }
            }
            .padding(.top, gap)
        case .clock(let clock):
            SessionClockView(clock: clock)
                .padding(.top, gap)
        }
    }

    // MARK: 단계

    @ViewBuilder
    private func stepsView(_ run: SessionStepRun) -> some View {
        if run.isGroup {
            groupView(run)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(run.stepIDs, id: \.self) { id in stepView(id) }
            }
        }
    }

    @ViewBuilder
    private func groupView(_ run: SessionStepRun) -> some View {
        let open = state.isOpen(run)
        if open {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    if state.hidesSteps(run) {
                        QuietLink(SessionViewCopy.showAll) { state.toggleShowAll(run) }
                            .frame(height: 24, alignment: .leading)
                            .padding(.leading, -6)
                    }
                    ForEach(state.visibleSteps(run), id: \.self) { id in stepView(id) }
                    if state.isShowingAll(run), run.stepIDs.count > SessionTimeline.visibleRecent {
                        QuietLink(SessionViewCopy.showLess) { state.toggleShowAll(run) }
                            .frame(height: 24, alignment: .leading)
                            .padding(.leading, -6)
                    }
                }
            } header: {
                groupHead(run, open: true)
            }
        } else {
            groupHead(run, open: false)
        }
    }

    /// 묶음 머리 (E3): 열린 머리는 본문 위에 붙고(패널 폭 전체 · `bg/elevated` 불투명) `text/primary`로 열림을 말한다. 개수는 접근성 이름에만
    private func groupHead(_ run: SessionStepRun, open: Bool) -> some View {
        SessionStepRowView(
            line: run.label, failed: false, expandable: true, isOpen: open, emphasized: open, showsChevronAtRest: true,
            accessibilityName: SessionViewCopy.steps(run.stepIDs.count), onToggle: { state.toggle(run) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, open ? TFSpace.lg : 0)
        .background { if open { TFColor.bgElevated } }
        .padding(.horizontal, open ? -TFSpace.lg : 0)
    }

    @ViewBuilder
    private func stepView(_ id: String) -> some View {
        if let info = steps[id] {
            VStack(alignment: .leading, spacing: 0) {
                SessionStepRowView(
                    line: info.line, failed: info.failed, expandable: info.canExpand, isOpen: state.isOpen(step: id),
                    onToggle: { state.toggle(step: id, load: loadDetail) }
                )
                if state.isOpen(step: id), case .loaded(let detail)? = state.details[id] { SessionStepDetailView(detail: detail) }
            }
        }
    }
}
#endif
