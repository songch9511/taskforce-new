#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 저장된 Claude 데스크톱 대화 읽기 패널 (OA D3v-m, DZ 승인 2026-10-23 `oa-desktop-chat-view-dz` 시트 2 · 3 · 5, 계약 27장): Sessions의 Saved chats 줄을 눌러 연다 (Sessions 왼쪽).
// Claude 세션 패널과 같은 모양이다: 보낸 말 + "Received · via Taskforce", 도구는 이름뿐인 단계 줄, 답은 같은 안전한 서식(`SessionMarkdownView`, 링크 없음).
// **입력창 · Open in Claude · "Worked for"가 없다.** 머리 단추는 Delete 하나: 확인 카드(입력창 자리, 모달 아님)를 거쳐서만 지우고 Undo가 없다.
// 글 · 제목 · id를 로그에 남기지 않는다.

/// 이 실행의 저장된 대화 저장소 (OA D3v-m): 목록(`ExternalSessionsRuntime.make`)과 **같은 게이트**다 — 새 Issues 화면 ∧ `BridgeFlag` ∧ 서비스 · 계정 경계. 로그인은 셸 모델이 본다 (`savedChatsVisible`).
/// 읽기는 Supabase 직접(RLS) · 지우기는 서버 API다. **중계 게이트(`ClaudeAppRelayGate`)와 상관없다**: 읽기 전용 보기는 내부 빌드가 아니어도 있다 (서버가 저장을 켠 뒤).
/// 이 Mac의 bridge id는 줄의 기기 이름을 생략할 때만 쓴다. 로그는 코드뿐이다 (제목 · 글 · id 0)
enum SavedChatsRuntime {
    @MainActor
    static func make(
        services: AppServices?, scope: AccountScope?, issueScreens: Bool, bridgeEnabled: Bool = BridgeFlag.current,
        host: @escaping @MainActor @Sendable () -> BridgeHost? = { BridgeHost.shared }
    ) -> SavedChatsStore? {
        guard issueScreens, bridgeEnabled, let services, let scope else { return nil }
        let log = BridgeOSLog()
        return SavedChatsLive.store(
            reads: services.reads, api: services.api, thisMac: thisMac(host: host), scope: scope, log: { event, code in log.log(event, ["code": .code(code)]) }
        )
    }

    /// 이 Mac의 bridge id (런타임이 없으면 모른다: 이름이 있는 Mac은 이름을 보인다)
    static func thisMac(host: @escaping @MainActor @Sendable () -> BridgeHost?) -> @Sendable () async -> UUID? {
        {
            guard let runtime = await MainActor.run(body: { host()?.activeRuntime }) else { return nil }
            return await runtime.localBridgeID()
        }
    }
}

/// 읽기 패널이 SwiftUI에 넘기는 값: 머리 · 본문 · 아래 카드의 높이 (창 높이를 맞춘다) · 나타남
@MainActor
@Observable
final class EdgeSavedChatPanelPresentation {
    var headHeight: CGFloat = 0
    var bodyHeight: CGFloat = 0
    var footerHeight: CGFloat = 0
    var shown = false
    /// 단계 묶음 · 줄의 보이는 상태
    let steps = SessionStepsState()
    /// 본문이 다시 계산돼도 말이 그대로면 타임라인을 다시 만들지 않는다
    @ObservationIgnored let timeline = SessionTimelineMemo<SavedChatTimelineInput, SavedChatTimeline>()

    var contentHeight: CGFloat { headHeight + bodyHeight + footerHeight }

    /// 지금 보는 대화 (같으면 아무 일도 없다)
    private(set) var chatKey: UUID?

    /// 다른 대화를 연다: 열어 둔 줄은 비운다 (줄 id는 대화 안에서만 겹치지 않는다)
    func beginChat(_ key: UUID) {
        guard key != chatKey else { return }
        chatKey = key
        steps.reset()
        timeline.reset()
    }
}

/// 타임라인의 입력 (같으면 같은 타임라인): 말 + 오늘 (날짜 줄의 "Today" · "Yesterday")
struct SavedChatTimelineInput: Equatable {
    var messages: [SavedChatMessage]
    var today: LocalDate
}

/// 읽기 패널이 무엇을 보이나 (순수한 판단: 시험이 상태마다 확인한다). 입력창 · Undo · 저장 표시는 어느 갈래에도 없다
struct SavedChatPanelPlan: Equatable {
    enum Body: Equatable {
        /// 처음 읽는 중 (글)
        case loading(String)
        /// 읽지 못했다: 굵은 첫 말 + Try again
        case failed(title: String, retry: String)
        case messages
    }

    /// 입력창 자리의 확인 · 실패 카드 (`ConfirmCard`: 빨강 없음)
    struct Card: Equatable {
        var title: String
        var detail: String?
        var meta: String?
        var confirmLabel: String
        var cancelLabel: String
        var busy: Bool
    }

    enum Footer: Equatable {
        case none
        case card(Card)
    }

    var title: String
    /// 머리 둘째 줄: "기기 이름 · Oct 22"
    var statusLine: String
    /// 머리 단추 (하나뿐)
    var headerAction: String
    var body: Body
    var footer: Footer

    @MainActor
    static func make(detail: SavedChatDetailModel, now: Date, timeZone: TimeZone = .current) -> SavedChatPanelPlan {
        let body: Body
        switch detail.phase {
        case .loading, .gone: body = .loading(ExternalSessionCopy.checking)
        case .failed: body = .failed(title: ClaudeAppCopy.couldNotLoadChat, retry: ClaudeAppCopy.tryAgain)
        case .ready: body = .messages
        }
        let footer: Footer
        switch detail.deleteState {
        case .none:
            footer = .none
        case .confirming:
            footer = .card(confirmCard(detail.chat, busy: false))
        case .deleting:
            footer = .card(confirmCard(detail.chat, busy: true))
        case .failed(let reason):
            // 굵은 첫 말 + 승인된 이유 줄 (빨강 없음). 주 단추는 Try again: 같은 지우기를 다시 보낸다
            footer = .card(Card(title: SavedChatsCopy.couldNotDelete, detail: reason.reason, meta: nil, confirmLabel: ExternalSessionCopy.tryAgain, cancelLabel: AgentCopy.cancel, busy: false))
        }
        return SavedChatPanelPlan(
            title: detail.chat.displayTitle, statusLine: detail.chat.headerLine(now: now, timeZone: timeZone), headerAction: SavedChatsCopy.delete, body: body, footer: footer
        )
    }

    /// "Delete this chat?" · 그 대화의 제목 · "Deletes the saved copy from all your devices" · Delete / Cancel (되돌리기 없음)
    private static func confirmCard(_ chat: SavedChatRow, busy: Bool) -> Card {
        Card(
            title: SavedChatsCopy.deleteChatTitle, detail: chat.displayTitle, meta: SavedChatsCopy.deleteChatDetail, confirmLabel: SavedChatsCopy.delete,
            cancelLabel: AgentCopy.cancel, busy: busy
        )
    }
}

/// 날짜가 바뀐 곳의 가운데 작은 줄 ("Oct 21" · "Yesterday")
private struct SavedChatDayLine: View {
    let label: String

    var body: some View {
        Text(label)
            .font(TFFont.footnote)
            .tracking(-0.08)
            .foregroundStyle(TFColor.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: TFSpace.xs, leading: 0, bottom: TFSpace.sm, trailing: 0))
    }
}

/// 답 하나: 세션 보기와 같은 안전한 서식의 글 + 밑 줄(왼쪽 시각, 오른쪽 Copy: 마우스를 올리거나 포커스가 있을 때만 보이고 **저장된 원문**을 복사한다 — 그림용 말줄임 "…"은 가져가지 않는다)
struct SavedChatReplyView: View {
    let markdown: String
    let copyText: String
    let time: String
    var revealed = false

    /// Copy 단추: 그리는 글(`markdown`, 잘린 답은 끝에 "…")이 아니라 저장된 원문(`copyText`)을 복사한다
    var copyButton: SessionCopyButton { SessionCopyButton(text: copyText, alwaysVisible: false, revealed: revealed) }

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.xs) {
            // 안전한 부분만 그린다 (코드 블록 · 인라인 코드 · 목록 · 굵게): 링크 · 표 · 이미지 · HTML은 쓴 그대로 글자다
            Message(isUser: false) { SessionMarkdownView(source: markdown) }
            HStack(spacing: 0) {
                Text(time)
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .monospacedDigit()
                    .foregroundStyle(TFColor.textSecondary)
                Spacer(minLength: 0)
                copyButton
                    .padding(.trailing, -7)
            }
            .frame(height: 28)
        }
    }
}

/// 말 한 줄: 보낸 말(쓴 그대로 + 밑 "Received · via Taskforce") 또는 답. 날짜가 바뀐 곳이면 위에 날짜 줄
struct SavedChatItemView: View {
    let item: SavedChatItem?
    let dayLabel: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dayLabel { SavedChatDayLine(label: dayLabel) }
            switch item {
            case .sent(let text)?:
                Message(isUser: true) { MessageText(text) }
                MessageDeliveryView(SavedChatItem.deliveryLine)
            case .reply?:
                if let reply = Self.replyView(item, revealed: hovering) { reply }
            case nil:
                EmptyView()
            }
        }
        .onHover { hovering = $0 }
    }

    /// 답이면 그 답의 그림 (아니면 nil): 시험이 복사 단추가 무엇을 복사하는지 본다
    static func replyView(_ item: SavedChatItem?, revealed: Bool) -> SavedChatReplyView? {
        guard case .reply(let markdown, let copyText, let time)? = item else { return nil }
        return SavedChatReplyView(markdown: markdown, copyText: copyText, time: time, revealed: revealed)
    }
}

/// 저장된 대화 읽기 패널 (DS PanelHeader 세션 변형 · 본문 · 아래 카드): 폭 380, 모서리 18, `panel` 재료, 높이는 내용에 맞춰 320–520
struct SavedChatPanelView: View {
    @Bindable var shell: EdgeShellModel
    @Bindable var presentation: EdgeSavedChatPanelPresentation

    private enum Anchor {
        static let bottom = "saved-chat-bottom"
    }

    var body: some View {
        let scale = TFMotion.panelTransform(shown: presentation.shown, reduceMotion: shell.reduceMotion).scale
        let shape = RoundedRectangle(cornerRadius: EdgePanelMetrics.radius, style: .continuous)
        Group {
            if let detail = shell.savedChatDetail, shell.savedChatPanelID == detail.chat.id {
                content(detail)
            } else {
                Color.clear
            }
        }
        .frame(width: EdgePanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(TFColor.bgPanel)
            }
        }
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .scaleEffect(scale, anchor: .topTrailing)
        .animation(TFMotion.move(TFMotion.panelMove, reduceMotion: shell.reduceMotion), value: presentation.shown)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shell.savedChatDetail?.chat.displayTitle ?? SavedChatsCopy.title)
    }

    @ViewBuilder
    private func content(_ detail: SavedChatDetailModel) -> some View {
        let plan = SavedChatPanelPlan.make(detail: detail, now: Date())
        VStack(spacing: 0) {
            PanelHeader(
                title: plan.title, agent: .claudeCode, pill: PanelHeaderPill(title: plan.headerAction) { detail.requestDelete() }, status: plan.statusLine
            )
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.headHeight = $0 }
            // 글이 짧으면 머리 바로 아래부터, 길면 맨 아래(가장 새 글)에서 시작한다
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        transcript(detail, plan: plan)
                            .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.lg, bottom: TFSpace.sm, trailing: TFSpace.lg))
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.automatic)
                    // "Show earlier"로 앞을 편 뒤 펴기 전의 첫 줄을 위에 붙잡는다 (`SessionEntriesView`)
                    .environment(\.sessionScrollToEntry, SessionScrollTo { id in proxy.scrollTo(id, anchor: .top) })
                }
            }
            footer(plan, detail)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.footerHeight = $0 }
        }
        .task(id: detail.chat.id) { presentation.beginChat(detail.chat.id) }
    }

    @ViewBuilder
    private func transcript(_ detail: SavedChatDetailModel, plan: SavedChatPanelPlan) -> some View {
        switch plan.body {
        case .loading(let text):
            Text(text)
                .font(TFFont.callout)
                .tracking(-0.24)
                .foregroundStyle(TFColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: TFSpace.xs, leading: TFSpace.xs, bottom: 0, trailing: 0))
        case .failed(let title, let retry):
            PanelEmptyState(title: title) {
                Button(retry) { detail.retry() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
            }
        case .messages:
            let input = SavedChatTimelineInput(messages: detail.messages, today: LocalDate(date: Date(), timeZone: .current))
            let timeline = presentation.timeline.value(for: input) { SavedChatTimeline.make(detail.messages, now: Date()) }
            VStack(alignment: .leading, spacing: 0) {
                // 위의 "Show earlier"가 앞 쪽(서버에서 20…40개)을 읽는다. 단계 · 줄은 세션 보기와 같은 본문이다 (시각 줄 · 복사 줄은 답이 스스로 그린다)
                SessionEntriesView(
                    entries: timeline.entries, steps: timeline.steps, state: presentation.steps,
                    earlierPage: SessionEarlierPage(available: detail.hasEarlier, loading: detail.loadingEarlier, load: { Task { await detail.showEarlier() } }),
                    item: { id in SavedChatItemView(item: timeline.items[id], dayLabel: timeline.dayLabel(of: id)) }, showsTime: false
                )
                Color.clear.frame(height: 1).id(Anchor.bottom)
            }
        }
    }

    /// 입력창 자리: 지우기 확인 · 지우는 중 · 실패 카드뿐이다 (입력창 없음)
    @ViewBuilder
    private func footer(_ plan: SavedChatPanelPlan, _ detail: SavedChatDetailModel) -> some View {
        switch plan.footer {
        case .none:
            Color.clear.frame(height: TFSpace.sm)
        case .card(let card):
            ConfirmCard(
                title: card.title, detail: card.detail, meta: card.meta, confirmLabel: card.confirmLabel, cancelLabel: card.cancelLabel, busy: card.busy, autoFocus: true,
                onConfirm: { Task { await detail.confirmDelete() } }, onCancel: { detail.cancelDelete() }
            )
            // 확인 → 지우는 중은 같은 카드(제목이 같다), 실패는 새 카드다: 다시 Cancel이 먼저 포커스를 받는다 (DZ 시트 3-3)
            .id(card.title)
            .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: TFSpace.md, trailing: TFSpace.md))
        }
    }
}

/// 저장된 대화 읽기 패널 창: `EdgeKeyPanel`과 같은 종류(borderless · nonactivating)의 창. Sessions가 떠 있는 동안 그 왼쪽 40pt에 서고(세션 패널과 같은 자리 규칙), 위를 Sessions에 맞춘다.
/// 눌렀을 때 키 창이 된다 (Sessions의 키를 빼앗지 않는다)
@MainActor
final class EdgeSavedChatPanelController {
    let shell: EdgeShellModel
    let panel: EdgeKeyPanel
    let presentation = EdgeSavedChatPanelPresentation()
    private let hosting: NSHostingView<SavedChatPanelView>
    private var generation = 0
    /// 메인 패널(Sessions) 창의 마지막으로 정해진 자리 (보이는 동안만). 이 창은 그 왼쪽에 놓인다
    var mainPanelFrame: () -> NSRect? = { nil }

    init(shell: EdgeShellModel) {
        self.shell = shell
        panel = EdgeKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: EdgePanelMetrics.width, height: EdgePanelMetrics.minHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false
        )
        hosting = NSHostingView(rootView: SavedChatPanelView(shell: shell, presentation: presentation))
        hosting.sizingOptions = []
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = hosting
        panel.setAccessibilityLabel(SavedChatsCopy.title)
    }

    var isVisible: Bool { panel.isVisible }

    /// 높이: 내용에 맞춰 320–520 (세션 패널과 같다)
    func height() -> CGFloat {
        min(EdgePanelMetrics.maxHeight, max(EdgePanelMetrics.minHeight, presentation.contentHeight))
    }

    /// 지금 자리: Sessions 왼쪽 40pt, 위 맞춤 (메인 패널 창이 아직 없으면 nil)
    func targetFrame() -> NSRect? {
        guard let main = mainPanelFrame() else { return nil }
        return EdgeSessionPanelController.frame(issuePanel: main, height: height())
    }

    /// 열었으면 true (자리를 못 정하면 false)
    @discardableResult
    func show() -> Bool {
        hosting.layoutSubtreeIfNeeded()
        guard let target = targetFrame() else { return false }
        generation += 1
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(target, display: false)
        } else {
            panel.setFrame(target, display: true)
        }
        // 키를 빼앗지 않는다: 눌렀을 때 키 창이 된다
        panel.orderFrontRegardless()
        presentation.shown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            panel.animator().alphaValue = 1
        }
        return true
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let current = generation
        presentation.shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TFMotion.panelFade
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TFMotion.panelFade))
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        }
    }

    /// 내용 높이 · 메인 패널 자리가 바뀌면 위를 맞춘 채로 맞춘다
    func fit() {
        guard panel.isVisible, presentation.shown, let target = targetFrame(), !EdgePanelMotion.isSameFrame(target, panel.frame) else { return }
        EdgePanelMotion.move(panel, to: target, reduceMotion: shell.reduceMotion)
    }
}
#endif
