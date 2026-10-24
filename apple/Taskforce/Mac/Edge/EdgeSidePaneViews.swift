#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 패널 옆줄의 그림 (DZ oa-session-view-dz v2 E7–E10): 접힘 = 폭 36 띠(세로 글 "Background tasks · {상태}" + 바깥으로 여는 chevron), 펼침 = 폭 256 옆줄(머리 + 일 줄 목록, 안에서 스크롤),
// 일을 누르면 같은 옆줄 안에서 출력 꼬리(머리가 Back + 일 이름). 패널과 같은 재질 · 같은 위 · 같은 높이, 맞닿은 모서리는 직각이고 맞닿은 면에는 1px 헤어라인만 있다.
// 색은 DS 토큰만이다 (빨강 없음: 실패는 굵은 "Failed"와 회색 이유).

enum SidePaneShapes {
    /// 패널: 옆줄과 맞닿은 왼쪽 모서리는 직각 (옆줄이 이어받는다)
    static func panel(attachedLeading: Bool) -> UnevenRoundedRectangle {
        let leading = attachedLeading ? 0 : EdgePanelMetrics.radius
        return UnevenRoundedRectangle(
            topLeadingRadius: leading, bottomLeadingRadius: leading, bottomTrailingRadius: EdgePanelMetrics.radius, topTrailingRadius: EdgePanelMetrics.radius, style: .continuous
        )
    }

    /// 옆줄 · 띠: 바깥(왼쪽) 모서리 18, 맞닿은(오른쪽) 모서리 직각
    static let side = UnevenRoundedRectangle(
        topLeadingRadius: EdgePanelMetrics.radius, bottomLeadingRadius: EdgePanelMetrics.radius, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
    )
}

/// 옆줄의 면: 패널과 같은 재질(`panel` 97% 불투명 + 블러) · 오른쪽(맞닿은 면)에 1px 헤어라인. `overlaying`이면 패널 위로 덮는 것이라 오른쪽 가장자리 그림자가 있다
struct SidePaneSurface<Content: View>: View {
    var overlaying = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .background {
                ZStack {
                    SidePaneShapes.side.fill(.ultraThinMaterial)
                    SidePaneShapes.side.fill(TFColor.bgPanel)
                }
            }
            .clipShape(SidePaneShapes.side)
            .overlay(alignment: .trailing) { Rectangle().fill(TFColor.borderDefault).frame(width: 1) }
            .shadow(color: overlaying ? .black.opacity(scheme == .dark ? 0.5 : 0.18) : .clear, radius: overlaying ? 10 : 0, x: overlaying ? 4 : 0, y: 0)
    }
}

/// 접힌 띠 (E7): 띠 전체가 단추다. chevron 28×28 칸(위 패딩 10 → 중심 y 24 = 패널 머리 제목의 중심) · 세로 라벨은 y 46에서 시작. 호버 `bg/selected` · 포커스 2px `border/accent`
struct SidePaneStrip: View {
    @Bindable var model: SessionSidePaneModel
    @State private var hovering = false
    @State private var labelWidth: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        let status = model.effective.stripStatus
        Button { model.expand() } label: {
            VStack(spacing: 0) {
                TFIcon.back.image(size: 14)
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .padding(.top, 10)
                label(status)
                    .padding(.top, TFSpace.sm)
                Spacer(minLength: 0)
            }
            .frame(width: SidePaneLayout.stripWidth)
            .frame(maxHeight: .infinity)
            .background(hovering ? TFColor.bgSelected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .overlay {
            if focused { RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous).strokeBorder(TFColor.borderAccent, lineWidth: 2).padding(4) }
        }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        .accessibilityLabel(model.effective.accessibleName)
        .accessibilityValue(SessionAccessibility.state(expanded: false))
        .accessibilityAddTraits(.isButton)
    }

    /// 세로 라벨: 위에서 아래로 읽는다 ("Background tasks" 600 `text/primary` · 상태 400 `text/secondary`, Failed는 600 `text/primary`)
    private func label(_ status: BackgroundTaskStatus?) -> some View {
        let lit = hovering
        var text = Text(SessionViewCopy.backgroundTasks).font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary)
        if let status {
            let word = Text(" · \(status.word)")
            text = text + (status == .failed ? word.font(TFFont.footnoteEmphasis).foregroundStyle(TFColor.textPrimary) : word.font(TFFont.footnote).foregroundStyle(lit ? TFColor.textSecondarySelected : TFColor.textSecondary))
        }
        return text
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { labelWidth = $0 }
            .rotationEffect(.degrees(90))
            .frame(width: 18, height: labelWidth)
            .accessibilityHidden(true)
    }
}

/// 펼친 옆줄의 머리 (DS 패널 머리 치수 그대로: 패딩 12 10 8 16, 제목 15/20 600) + 상태 줄 (13/18, 패딩 0 16 10, Failed는 600 `text/primary`)
struct SidePaneHeader<Leading: View>: View {
    let title: String
    let status: BackgroundTaskStatus?
    /// 상태 줄을 이 글로 대신한다 (꼬리 보기: "종류 · 상태 · 시간", 실패한 일은 "Failed"만 굵다)
    var statusText: Text?
    @ViewBuilder var leading: Leading
    var trailing: () -> AnyView = { AnyView(EmptyView()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TFSpace.xs) {
                leading
                Text(title)
                    .font(TFFont.calloutEmphasis)
                    .tracking(-0.24)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                trailing()
            }
            .frame(height: 24)
            .padding(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0))
            if let line = statusText ?? status.map({ Text($0.word) }) {
                line
                    .font(status == .failed && statusText == nil ? TFFont.footnoteEmphasis : TFFont.footnote)
                    .tracking(-0.08)
                    .monospacedDigit()
                    .foregroundStyle(status == .failed && statusText == nil ? TFColor.textPrimary : TFColor.textSecondary)
                    .lineLimit(1)
                    .padding(.bottom, 10)
            }
        }
        .padding(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: 0, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 둘째 줄 "종류 · 상태 · 시간" (E9): 실패한 일의 "Failed" 한 단어만 굵다 (600 `text/primary`, 빨강 없음). 나머지는 부르는 쪽의 글꼴 · 색. 트리 줄과 같은 글이라 구현은 한 곳(`SubagentTreeRowView`)에 있다
enum SidePaneMeta {
    static func text(_ task: TaskforceKit.BackgroundTask, now: Date) -> Text { SubagentTreeLook.metaText(task, now: now) }
}

/// 1초 시계는 도는 일이 있을 때만 필요하다 (끝난 줄의 글은 `now`에 기대지 않는다: `BackgroundTask.meta`). 도는 일이 없으면 목록을 1초마다 다시 그리지 않는다
enum SidePaneClock {
    static func ticks(_ tasks: BackgroundTaskList) -> Bool { tasks.runningCount > 0 }
    static func ticks(_ task: TaskforceKit.BackgroundTask) -> Bool { task.status == .running }

}

/// `ticking`이면 1초마다 `now`를 새로 주고, 아니면 그릴 때의 시각 하나로 그린다 (타이머가 없다)
struct SidePaneClockView<Content: View>: View {
    let ticking: Bool
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if ticking {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        } else {
            content(Date())
        }
    }
}

/// 펼친 옆줄: 목록 또는 (일을 눌렀으면) 출력 꼬리. 머리는 고정이고 줄은 안에서 스크롤한다
struct SidePaneBody: View {
    @Bindable var model: SessionSidePaneModel
    var reduceMotion = false

    var body: some View {
        VStack(spacing: 0) {
            if let task = model.selected {
                tailView(task)
            } else {
                list
            }
        }
        .frame(width: SidePaneLayout.paneWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SessionViewCopy.backgroundTasks)
        .accessibilityValue(SessionAccessibility.state(expanded: true))
    }

    // MARK: 목록

    private var list: some View {
        let tasks = model.effective
        let rows = model.treeRows
        return VStack(spacing: 0) {
            SidePaneHeader(title: SessionViewCopy.backgroundTasks, status: tasks.stripStatus, leading: { EmptyView() }, trailing: {
                AnyView(TFIconButton(.disclosureClosed, label: SessionViewCopy.hideBackgroundTasks, size: 14) { model.collapse() }.padding(.vertical, -2))
            })
            ScrollView {
                SidePaneClockView(ticking: SidePaneClock.ticks(tasks)) { now in
                    // 즉시 쌓기 `VStack`이다 (21-7: 게으른 쌓기로 바꾸지 않는다). 줄 id는 일 id라 갱신 중에도 같은 줄은 같은 줄이다: 선택 · 스크롤이 튀지 않는다
                    VStack(spacing: TFSpace.xxs) {
                        ForEach(rows) { row in
                            SubagentTreeRowView(row: row, now: now, reduceMotion: reduceMotion, onOpen: { model.select(row.task.id) }, onToggle: { model.toggleBranch(row.task.id, level: row.level) })
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: TFSpace.sm, bottom: TFSpace.md, trailing: TFSpace.sm))
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: 꼬리

    private func tailView(_ task: TaskforceKit.BackgroundTask) -> some View {
        VStack(spacing: 0) {
            SidePaneClockView(ticking: SidePaneClock.ticks(task)) { now in
                SidePaneHeader(title: task.title, status: nil, statusText: SidePaneMeta.text(task, now: now), leading: {
                    TFIconButton(.back, label: SessionViewCopy.back, size: 14) { model.back() }.padding(.leading, -TFSpace.sm)
                })
            }
            if let tail = model.tail {
                SidePaneTail(tail: tail, task: task)
            } else {
                Text(SessionViewCopy.couldNotLoadOutput)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TFSpace.lg)
                Spacer(minLength: 0)
            }
        }
    }
}

/// 출력 꼬리 (E10): 파일 끝을 읽어 맨 아래를 따라간다 (위로 올려 읽는 중이면 끌어내리지 않는다). 위에 Show earlier(창을 넓힌다). 에이전트는 그 에이전트의 말 + 단계 줄 + 시계 줄
struct SidePaneTail: View {
    @Bindable var tail: BackgroundTaskTailModel
    let task: TaskforceKit.BackgroundTask
    @State private var pinned = true
    @State private var steps = SessionStepsState()

    private enum Anchor { static let bottom = "side-pane-tail-bottom" }

    var body: some View {
        // 짧은 출력은 머리 바로 아래부터, 길면 맨 아래(가장 새 줄)에서 시작한다: 보이는 높이를 최소 높이로 줘 위에 붙인다 (대화 본문과 같은 방식)
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: TFSpace.sm) {
                        content
                        Color.clear.frame(height: 1).id(Anchor.bottom)
                    }
                    .padding(EdgeInsets(top: 0, leading: TFSpace.sm, bottom: TFSpace.md, trailing: TFSpace.sm))
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.automatic)
                .environment(\.sessionScrollToEntry, SessionScrollTo { id in proxy.scrollTo(id, anchor: .top) })
                .onScrollGeometryChange(for: SessionScrollSnapshot.self) { geometry in
                    SessionScrollSnapshot(visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height, visibleHeight: geometry.visibleRect.height)
                } action: { old, new in
                    pinned = SessionScrollPin.next(pinned: pinned, old: old, new: new)
                }
                .onChange(of: tail.state) {
                    if SessionScrollPin.shouldFollowNewContent(pinned: pinned) { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
                }
                // 다른 일의 꼬리를 열면 열어 둔 묶음 · 편 창(가장 새 150줄 → Show earlier)을 비운다: 줄 id는 일 안에서만 겹치지 않는다
                .onChange(of: task.id) { steps.reset() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tail.state {
        case .loading:
            Color.clear.frame(height: 0)
        case .empty:
            note(SessionViewCopy.noOutputYet)
        case .unavailable:
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                note(SessionViewCopy.couldNotLoadOutput)
                Button(SessionViewCopy.tryAgain) { tail.retry() }.buttonStyle(TFButtonStyle(.secondary, size: .sm)).padding(.horizontal, TFSpace.sm)
            }
        case .text(let text, let earlier):
            if earlier { earlierLink }
            SessionCodeBlockView(label: SessionViewCopy.output, text: text, collapses: false)
        case .agent(let turns, let earlier):
            agent(turns, earlier: earlier)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(TFFont.footnote)
            .tracking(-0.08)
            .foregroundStyle(TFColor.textSecondary)
            .padding(.horizontal, TFSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var earlierLink: some View {
        HStack {
            Spacer(minLength: 0)
            QuietLink(SessionViewCopy.showEarlier) { tail.showEarlier() }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func agent(_ turns: [ClaudeAppTurn], earlier: Bool) -> some View {
        let data = SessionTimelineSource.claude(turns)
        let running = task.status == .running
        // 도는 일은 마지막 묶음이 열려 있다. 끝난 일에는 답 밑 줄이 없다 (그 말은 에이전트의 것이고 이 옆줄은 읽기만 한다)
        let entries = SessionTimeline.build(data.items, state: running ? .running : .finished).filter { if case .footer = $0 { false } else { true } }
        let byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Show earlier는 본문이 하나만 세운다: 창 밖에 읽어 둔 줄을 먼저 펴고, 다 폈으면 꼬리의 창을 넓힌다 (`tail.showEarlier()`)
        SessionEntriesView(entries: entries, steps: data.steps, state: steps, earlierPage: SessionEarlierPage(available: earlier, load: { tail.showEarlier() }), pinnedToBottom: pinned, item: { id in
            if let turn = byID[id], case .assistant(let text) = turn.kind { SessionMarkdownView(source: turn.truncated ? text + "…" : text) }
        })
        .padding(.horizontal, TFSpace.sm)
        // 옆줄 꼬리의 코드 면은 패널 본문보다 훨씬 좁다 (옆줄 256 − 꼬리 안쪽 여백 · 줄 여백 sm × 4): 줄바꿈이 많아 접을지 셀 때의 한 줄 칸 수가 다르다
        .environment(\.sessionCodeBlockWidth, SidePaneLayout.paneWidth - 4 * TFSpace.sm)
        if running, let started = task.startedAt { SessionClockView(clock: SessionClock(id: "clock-\(task.id)", since: started), state: steps).padding(.horizontal, TFSpace.sm) }
    }
}
#endif
