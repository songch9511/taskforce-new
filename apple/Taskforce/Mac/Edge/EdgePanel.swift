#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// EdgePanel의 자리 (디자인 README › Layout): 380pt 폭, 모서리 18, 내용에 맞춰 520pt까지. 펼친 레일 왼쪽 12pt, 위가 레일과 같다.
enum EdgePanelMetrics {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 520
    static let minHeight: CGFloat = 120
    static let radius: CGFloat = TFRadius.lg
    /// 레일과의 간격 (`space-md`)
    static let gap: CGFloat = TFSpace.md
    /// 머리 줄: 위 12 + 제목 20 + 아래 8
    static let headerHeight: CGFloat = 40

    /// 본문 높이에 맞춘 패널 높이
    static func height(body: CGFloat) -> CGFloat {
        min(maxHeight, max(minHeight, headerHeight + body))
    }

    /// 패널 창의 자리 (화면 좌표, 아래가 0). 오른쪽은 펼친 레일 왼쪽에서 12pt, 위는 레일 위 모서리
    static func frame(height: CGFloat, railTop: CGFloat, screenMaxX: CGFloat) -> NSRect {
        NSRect(x: screenMaxX - EdgeRailLayout.railWidth - gap - width, y: railTop - height, width: width, height: height)
    }
}

/// 패널 창이 SwiftUI에 넘기는 값: 본문 높이(창 높이를 맞춘다) · 나타남(크기 .975 → 1)
@MainActor
@Observable
final class EdgePanelPresentation {
    var bodyHeight: CGFloat = 0
    var shown = false
}

/// 패널 (디자인 EdgePanel): 머리 · 본문 · (입력칸). 자기 탐색이 없고 닫기 버튼도 없다. 한 번에 한 화면.
struct EdgePanelView: View {
    @Bindable var shell: EdgeShellModel
    @Bindable var presentation: EdgePanelPresentation

    var body: some View {
        // 이동(16pt)은 창이 움직이고, 크기(.975 → 1)는 여기서. 움직임 줄이기면 둘 다 없다
        let scale = TFMotion.panelTransform(shown: presentation.shown, reduceMotion: shell.reduceMotion).scale
        VStack(spacing: 0) {
            PanelHeader(title: shell.view.title)
            ScrollView {
                Group {
                    switch shell.view {
                    case .allWork:
                        EdgeWorkList(work: shell.work, currentID: shell.currentID, highlightedID: shell.hoveredID)
                    case .chats:
                        EdgeEmptyText(title: EdgeEmptyText.noChats)
                    }
                }
                .padding(EdgeInsets(top: 0, leading: TFSpace.lg, bottom: TFSpace.md, trailing: TFSpace.lg))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: EdgePanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: EdgePanelMetrics.radius, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: EdgePanelMetrics.radius, style: .continuous).fill(TFColor.bgPanel)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: EdgePanelMetrics.radius, style: .continuous))
        .scaleEffect(scale, anchor: .topTrailing)
        .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: shell.reduceMotion), value: presentation.shown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Taskforce")
    }
}

/// All work (뼈대): 기존 목록(`/api/v1/now`)의 일. 프로젝트 묶음 · 검색 · 필터 · 빈 화면 5종은 S3에서.
/// 열린 일(Review · In Progress · To Do) 다음에 조용한 Done today. 활동이 바뀌어도 줄 순서는 서버 순서 그대로.
struct EdgeWorkList: View {
    let work: EdgeWorkSnapshot
    let currentID: UUID?
    let highlightedID: UUID?
    var today = DueDateFormat.today()

    var body: some View {
        if work.isEmpty {
            if work.isLoaded { EdgeEmptyText(title: EdgeEmptyText.noWork) }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(open, id: \.action.id) { row in
                    EdgeWorkRow(row: row, today: today, current: row.action.id == currentID, highlighted: row.action.id == highlightedID)
                }
                if !work.doneToday.isEmpty {
                    Text("Done today")
                        .font(TFFont.caption)
                        .foregroundStyle(TFColor.textSecondary)
                        .padding(EdgeInsets(top: 18, leading: TFSpace.sm, bottom: TFSpace.xs, trailing: TFSpace.sm))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(work.doneToday, id: \.id) { action in
                        EdgeWorkRow(row: .init(action: action, state: .done, activity: nil), today: today, current: action.id == currentID, highlighted: action.id == highlightedID)
                    }
                }
            }
        }
    }

    private var open: [EdgeWorkRow.Row] {
        let review = work.review.map { EdgeWorkRow.Row(action: $0, state: .review, activity: ActivityRing.Kind.needsYou.accessibilityLabel) }
        let rest = work.open.map { action in
            let activity: String? = work.working.contains(action.id)
                ? (work.stopping.contains(action.id) ? "Stop requested · not confirmed" : ActivityRing.Kind.running.accessibilityLabel)
                : nil
            return EdgeWorkRow.Row(action: action, state: TaskStatusMark.State(TaskGroup.open(action)), activity: activity)
        }
        return review + rest
    }
}

/// 일 한 줄 (디자인 WorkRow의 뼈대): 상태 표시 · 제목 · 활동 · 기한. 줄 머리선은 글자에서 시작, 끝난 일은 조용하게(취소선 없음).
/// 접근성 이름 "Title — State · Activity, due Day" (기한이 지났으면 "overdue")
struct EdgeWorkRow: View {
    struct Row {
        let action: ActionSummary
        let state: TaskStatusMark.State
        let activity: String?
    }

    let row: Row
    let today: LocalDate
    /// 레일에서 연 일 (선택된 행)
    let current: Bool
    /// 패널이 열린 채 레일에서 그 일에 포인터를 올림 (표시만, 선택이 아니다)
    var highlighted = false

    static func accessibilityLabel(title: String, state: TaskStatusMark.State, activity: String?, due: String?, overdue: Bool) -> String {
        var label = "\(title) — \(state.label)"
        if let activity { label += " · \(activity)" }
        if let due { label += overdue ? ", overdue, due \(due)" : ", due \(due)" }
        return label
    }

    var body: some View {
        // 기한이 지나도 날짜를 쓴다 (빨강 · 굵게, "overdue"는 접근성 이름에만)
        let due = row.action.dueDate.map { DueText.short($0, today: today) }
        let overdue = row.state != .done && row.action.dueDate.map { DueText.isOverdue($0, today: today) } == true
        HStack(alignment: .top, spacing: TFSpace.md) {
            TaskStatusMark(row.state)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.action.title)
                    .font(TFFont.callout)
                    .tracking(-0.24)
                    .foregroundStyle(row.state == .done ? secondary : TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let activity = row.activity {
                    Text(activity)
                        .font(TFFont.footnote)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let due {
                Text(due)
                    .font(overdue ? TFFont.footnoteEmphasis : TFFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(overdue ? TFColor.statusOverdue : secondary)
                    .padding(.top, 1)
            }
        }
        .padding(EdgeInsets(top: 10, leading: TFSpace.sm, bottom: 10, trailing: TFSpace.sm))
        .background {
            RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous).fill(current || highlighted ? TFColor.bgSelected : .clear)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: row.action.title, state: row.state, activity: row.activity, due: due, overdue: overdue))
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var secondary: Color { current || highlighted ? TFColor.textSecondarySelected : TFColor.textSecondary }
}

/// 패널 안 빈 화면의 제목 (설명 문단 없음). "All caught up"은 쓰지 않는다 (디자인 EmptyState)
struct EdgeEmptyText: View {
    /// All work에 일이 하나도 없음 (Add task · Connect a source 버튼은 S3)
    static let noWork = "Nothing on your plate yet."
    /// Chats에 대화가 없음 (New chat은 B3)
    static let noChats = "No conversations yet."

    let title: String

    var body: some View {
        Text(title)
            .font(TFFont.calloutEmphasis)
            .foregroundStyle(TFColor.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, TFSpace.xl)
    }
}

/// 키를 받는 패널 창 (다른 앱을 앞에 둔 채로, Spotlight처럼)
final class EdgeKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 패널 창: 열 때 투명도 180ms + 오른쪽 16pt에서 260ms(크기 .975 → 1), 닫을 때 거꾸로. 움직임 줄이기면 투명도만.
@MainActor
final class EdgePanelController {
    let shell: EdgeShellModel
    let panel: EdgeKeyPanel
    let presentation = EdgePanelPresentation()
    private let hosting: NSHostingView<EdgePanelView>
    private var generation = 0
    /// 여는 움직임 중 (그동안 높이 맞추기는 끝난 뒤로 미룬다)
    private var opening = false

    init(shell: EdgeShellModel) {
        self.shell = shell
        panel = EdgeKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: EdgePanelMetrics.width, height: EdgePanelMetrics.maxHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hosting = NSHostingView(rootView: EdgePanelView(shell: shell, presentation: presentation))
        hosting.sizingOptions = []
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 그림자는 macOS가 창 모양(둥근 모서리)을 따라 그린다 (`shadow-float`)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    /// 지금 본문에 맞는 자리
    private func targetFrame() -> NSRect? {
        guard let screen = EdgeRailPanelController.screen else { return nil }
        return EdgePanelMetrics.frame(
            height: EdgePanelMetrics.height(body: presentation.bodyHeight),
            railTop: EdgeRailPanelController.railTop(on: screen),
            screenMaxX: screen.frame.maxX
        )
    }

    /// 열었으면 true (화면을 찾지 못하면 false)
    @discardableResult
    func show() -> Bool {
        // 처음 열 때도 본문 높이를 알고 자리를 잡는다
        hosting.layoutSubtreeIfNeeded()
        guard let target = targetFrame() else { return false }
        generation += 1
        let current = generation
        let reduceMotion = shell.reduceMotion
        // 닫히는 중에 다시 열면 지금 모습에서 이어서 연다 (투명도 · 자리를 처음으로 되돌리지 않는다)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(reduceMotion ? target : target.offsetBy(dx: TFMotion.panelHiddenOffset, dy: 0), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        presentation.shown = true
        opening = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            context.timingFunction = Self.timing
            panel.animator().alphaValue = 1
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : TFMotion.panelMove
            context.timingFunction = Self.timing
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.opening = false
                self.fitToContent()
                self.panel.invalidateShadow()
            }
        }
        return true
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let current = generation
        let reduceMotion = shell.reduceMotion
        opening = false
        presentation.shown = false
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            context.timingFunction = Self.timing
            panel.animator().alphaValue = 0
        }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TFMotion.panelMove
                context.timingFunction = Self.timing
                panel.animator().setFrame(frame.offsetBy(dx: TFMotion.panelHiddenOffset, dy: 0), display: true)
            }
        }
        // 가장 긴 움직임이 끝나면 창을 내린다. 그 사이 다시 열었으면 둔다
        let longest = reduceMotion ? TFMotion.panelFade : TFMotion.panelMove
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(longest))
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    /// 본문 높이가 바뀌면 위 모서리를 둔 채로 높이만 맞춘다
    func fitToContent() {
        guard !opening, panel.isVisible, presentation.shown, let target = targetFrame(), target != panel.frame else { return }
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    private static let timing = CAMediaTimingFunction(
        controlPoints: Float(TFMotion.easeControlPoints.x1), Float(TFMotion.easeControlPoints.y1),
        Float(TFMotion.easeControlPoints.x2), Float(TFMotion.easeControlPoints.y2)
    )
}
#endif
