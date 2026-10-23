#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 두 세션 패널이 같이 그리는 본문의 줄들 (DZ oa-session-view-dz v2): `SessionTimeline`이 정한 순서 그대로 — 말 · 단계 줄 · 접힌 묶음 · 답 밑 줄 · 도는 중 시계.
/// 말(사용자 · 어시스턴트 · 이벤트)은 쓰는 쪽이 그린다 (`item`): Claude 패널은 읽기 전용 말풍선, Taskforce 패널은 전달 줄 · View full이 붙은 줄.
/// 간격은 4/8 격자다: 블록 사이 12, 복사 줄은 답 바로 밑 4, 답 위의 "Worked for"는 답에 4로 붙는다.
/// **즉시 쌓기 `VStack`이다 (`LazyVStack`이 아니다)**: 게으른 쌓기는 아직 그리지 않은 줄의 높이를 어림해 스크롤 위치마다 내용 높이가 크게 달라지고(실측 2배–10배),
/// 맨 아래에 붙은 스크롤 · 창 높이 맞춤 · 스크롤 위치 알림이 그 흔들림을 먹으며 끝없이 다시 배치해 앱이 멈췄다 (#187 핫픽스, `agent-gateway.md` 21-7). 줄은 상한(1000)까지라 한꺼번에 그려도 된다.
/// 그래서 열린 묶음의 머리는 패널 본문 위에 붙지 않는다 (DZ E3 "머리 붙임"은 `LazyVStack`의 고정 머리에만 있다: 즉시 쌓기에는 없다. 머리는 줄 사이에 그대로 선다)
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

    /// 항목 위 간격 (4/8 격자): 첫 항목은 0, 답 밑 복사 줄 · 턴 끝의 시간 줄 · 시계 줄은 바로 밑 4, 나머지는 블록 사이 12.
    /// "Worked for"가 답 위에 서는 턴(사용자 결정 2026-10-23): 그 시간 줄은 앞 블록과 12 떨어지고, 그 바로 뒤의 답은 시간 줄에 4로 붙는다
    static func gap(before entry: SessionEntry, at index: Int, previous: SessionEntry? = nil) -> CGFloat {
        guard index > 0 else { return 0 }
        switch entry {
        case .footer(let footer): return footer.aboveAnswer ? TFSpace.md : TFSpace.xs
        case .clock: return TFSpace.xs
        case .item:
            if case .footer(let footer)? = previous, footer.aboveAnswer { return TFSpace.xs }
            return TFSpace.md
        case .steps: return TFSpace.md
        }
    }

    var body: some View {
        let footerIDs = Set(entries.compactMap { entry -> String? in if case .footer(let footer) = entry { footer.id } else { nil } })
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                entryView(entry, index: index, footerIDs: footerIDs)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: SessionEntry, index: Int, footerIDs: Set<String>) -> some View {
        let gap = Self.gap(before: entry, at: index, previous: index > 0 ? entries[index - 1] : nil)
        switch entry {
        case .item(let id):
            item(id)
                .padding(.top, gap)
                .onHover { inside in
                    // 이 답의 복사 줄이 있으면 답 위 호버가 줄의 복사 아이콘을 드러낸다 (복사 줄은 답 바로 밑에 서고, 일한 시간은 답 바로 위에 따로 선다)
                    let footer = "footer-\(id)"
                    guard footerIDs.contains(footer) else { return }
                    if inside { state.hoveredFooter = footer } else if state.hoveredFooter == footer { state.hoveredFooter = nil }
                }
        case .steps(let run):
            stepsView(run).padding(.top, gap)
        case .footer(let footer):
            SessionFooterView(footer: footer, revealed: state.hoveredFooter == footer.id, showsTime: showsTime) { inside in
                if inside { state.hoveredFooter = footer.id } else if state.hoveredFooter == footer.id { state.hoveredFooter = nil }
            }
            .padding(.top, gap)
        case .clock(let clock):
            SessionClockView(clock: clock, state: state)
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
            VStack(alignment: .leading, spacing: 0) {
                groupHead(run, open: true)
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
            }
        } else {
            groupHead(run, open: false)
        }
    }

    /// 묶음 머리 (E3): 열린 머리는 패널 폭 전체 · `bg/elevated` 띠이고 `text/primary`로 열림을 말한다 (본문 위에 붙지는 않는다). 개수는 접근성 이름에만
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
