#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// 에이전트 대화의 줄 동작을 화면에 잇는 값 (OA D4a-1): Assistant 창과 세션 패널이 같은 `AssistantTurnView`를 그린다.
/// 전달 줄의 말 · Send again · 후보 고르기 메뉴 · View full은 Kit(`AgentTurnDesk` · `MessageDeliveryLine` · `MessageViewFull`)이 정하고 여기는 그리기만 한다
struct AgentTurnActions {
    /// 이 글 아래의 전달 줄 (에이전트가 아니거나 아직 읽기 전이면 nil)
    var line: (ChatTurn) -> MessageDeliveryLine? = { _ in nil }
    /// 줄의 링크: Send again · 후보 고르기 (메뉴를 연다)
    var onLink: (ChatTurn, MessageDeliveryLine.Link) -> Void = { _, _ in }
    var viewFull: (ChatTurn) -> Void = { _ in }
    /// 오류 줄 · 동의 안내의 Try again (Send again · 후보 고르기를 다시 한다)
    var retry: (ChatTurn) -> Void = { _ in }
    /// 열린 후보 메뉴
    var referentMenu: AgentReferentMenu?
    var chooseReferent: (UUID) -> Void = { _ in }
    /// 후보의 줄 이름: "#번호 제목" (번호를 모르면 제목)
    var candidateLabel: (AgentReferentCandidate) -> String = { $0.title }

    static var none: AgentTurnActions { AgentTurnActions() }
}

/// 대화의 한 줄: 사용자 글(+ 전달 줄 또는 상태 한 줄) · 서버가 쓴 이벤트 줄 · Taskforce · 에이전트의 말(+인용 · 기억 노트 · 잘린 글의 View full)
struct AssistantTurnView: View {
    let turn: ChatTurn
    let runtime: ChatRuntime
    var actions = AgentTurnActions.none
    let onRetry: (UUID) -> Void

    var body: some View {
        if turn.isEvent {
            // 서버가 쓴 한 줄: 앱은 글을 만들지 않는다 (Opened in Terminal · Resumed here · Queued messages cancelled …)
            EventLine(turn.text)
        } else if turn.isUser {
            VStack(alignment: .leading, spacing: 0) {
                Message(isUser: true) { MessageText(turn.text, isDeleted: turn.textDeleted) }
                if turn.showsDeliveryLine {
                    // 에이전트 대상: 서버가 계산한 전달 표시를 말로 (answered · 모르는 값은 줄이 없다). 후보 고르기가 거절돼도 아직 열려 있으면 이 줄의 링크가 남는다
                    if let line = actions.line(turn) {
                        MessageDeliveryView(line, onLink: { link in actions.onLink(turn, link) })
                    }
                }
                if turn.showsStatusLine {
                    // 첫 보내기 실패 · Send again / 후보 고르기의 거절(동의 철회 · 오류): 기존 상태 줄 + Try again (후보 고르기의 Try again은 메뉴를 다시 연다)
                    ChatStatusLine(
                        status: turn.status,
                        onRetry: { if turn.delivery != nil { actions.retry(turn) } else { turn.clientMessageID.map(onRetry) } }
                    )
                    .padding(.top, TFSpace.xs)
                }
                if let menu = actions.referentMenu, menu.messageID == turn.id {
                    AgentReferentMenuView(menu: menu, label: actions.candidateLabel, onChoose: actions.chooseReferent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, TFSpace.xs)
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                Message(isUser: false) {
                    VStack(alignment: .leading, spacing: TFSpace.sm) {
                        MessageText(MessageViewFull.shownText(turn), isDeleted: turn.textDeleted)
                        // 잘린 답 바로 아래 8: 이 Mac 원장에 전문이 있을 때만 링크가 보이고, 누르면 그 자리에서 펼친다
                        if MessageViewFull.showsLink(turn) {
                            LinkButton(MessageViewFull.title) { actions.viewFull(turn) }
                                .font(TFFont.footnote)
                                .tracking(-0.08)
                                .padding(.top, TFSpace.xs - TFSpace.sm)
                        }
                        ForEach(Array(turn.citations.enumerated()), id: \.offset) { _, citation in
                            CitationView(citation: citation, open: runtime.openURL)
                        }
                    }
                }
                ForEach(turn.rememberedIDs, id: \.self) { id in
                    RememberedNoteHost(id: id, memory: runtime.memory)
                }
            }
        }
    }
}

/// 후보 고르기 메뉴 (OA D4a-06): `needs_referent` 줄의 링크가 연다. U2 `ContextMenu`의 줄 모양(안쪽 5/8 · 모서리 6 · callout · 호버 `bg/selected`)과 줄 이동(`ContextMenuModel`: ↑ ↓ Return)을 그대로 쓰되,
/// 창 안에 줄 바로 아래로 **펴 열린다** (떠 있는 메뉴 창이 아니다): 폭은 본문 폭에 맞추고 후보 ≤ 3, "#번호 제목"은 한 줄에서 끝을 줄인다.
/// 면 `bg/elevated` · 모서리 12 · 안쪽 5 · 그림자 `shadow-float` + 가장자리 hairline (본문 위에서 보이도록). Esc는 창이 메뉴부터 닫는다 (`AssistantWindowModel.escapeInner`)
struct AgentReferentMenuView: View {
    let menu: AgentReferentMenu
    let label: (AgentReferentCandidate) -> String
    let onChoose: (UUID) -> Void
    @State private var model: ContextMenuModel?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let model = model ?? makeModel()
        let shape = RoundedRectangle(cornerRadius: TFRadius.panel, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                row(item, index: index, model: model)
            }
        }
        .padding(ContextMenuView.inset)
        .frame(maxWidth: .infinity)
        .background(TFColor.bgElevated, in: shape)
        .overlay(shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 0.5))
        // shadow-float: 0 1 2 / 0 16 40 −12
        .shadow(color: scheme == .dark ? .black.opacity(0.4) : Color(red: 40 / 255, green: 30 / 255, blue: 15 / 255).opacity(0.08), radius: 1, y: 1)
        .shadow(color: scheme == .dark ? .black.opacity(0.7) : Color(red: 40 / 255, green: 30 / 255, blue: 15 / 255).opacity(0.26), radius: 16, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AgentNewCopy.active.chooseReferent ?? "Menu")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.return) { model.activate(); return .handled }
        .onAppear {
            self.model = model
            focused = true
        }
    }

    private func row(_ item: ContextMenuItem, index: Int, model: ContextMenuModel) -> some View {
        let lit = model.highlighted == index
        return Button { model.pick(index) } label: {
            Text(item.label)
                .font(TFFont.callout)
                .tracking(-0.24)
                .foregroundStyle(TFColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(EdgeInsets(top: 5, leading: TFSpace.sm, bottom: 5, trailing: TFSpace.sm))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(lit ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.highlighted = index } else if model.highlighted == index { model.highlighted = nil }
        }
        .accessibilityLabel(item.label)
    }

    private func makeModel() -> ContextMenuModel {
        ContextMenuModel(items: menu.candidates.map { candidate in
            ContextMenuItem(id: candidate.actionID.uuidString, label: label(candidate)) { onChoose(candidate.actionID) }
        })
    }
}
#endif
