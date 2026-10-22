#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

// 도구 단계 (DZ oa-session-view-dz v2 E2 · E3 · E4): 네 개 이상 이어지면 접힌 한 줄(도구 이름을 처음 쓴 순서로), 폄 = 최근 여섯 + Show all, 줄 = "이름 · 파일 이름 | description", 실패는 굵은 "Failed",
// 줄을 누르면 Input · Result가 그 자리에서 열린다 (이 Mac의 기록에서 그 줄만 다시 읽는다). 색 · 아이콘 · 개수는 화면에 없다 (개수는 접근성 이름에만).

/// 단계 묶음 · 줄의 보이는 상태 (화면 상태: 서버 · 로그 0). 묶음은 사용자가 정한 것이 있으면 그대로, 없으면 도는 턴의 마지막 묶음만 열려 있고 끝나면 접힌다
@MainActor
@Observable
final class SessionStepsState {
    /// 한 줄 본문의 상태
    enum Detail: Equatable {
        case loading
        case loaded(ClaudeAppToolDetail)
        /// 읽을 수 없다 (줄 하나가 바뀌었거나 사라졌다): 아무것도 보이지 않는다
        case none
    }

    /// 사용자가 열거나 닫은 묶음 (묶음 id → 열림)
    private(set) var chosen: [String: Bool] = [:]
    /// Show all을 누른 묶음
    private(set) var shownAll: Set<String> = []
    /// 열린 줄
    private(set) var openSteps: Set<String> = []
    private(set) var details: [String: Detail] = [:]
    /// 마우스가 올라 있는 답 (그 답 밑 줄의 복사 아이콘이 나타난다): 줄 id
    var hoveredFooter: String?

    /// 읽어 둔 본문을 이만큼까지만 둔다 (오래된 것부터 버린다)
    static let maxDetails = 64
    @ObservationIgnored private var detailOrder: [String] = []

    func isOpen(_ run: SessionStepRun) -> Bool { chosen[run.id] ?? run.isLive }

    func toggle(_ run: SessionStepRun) {
        chosen[run.id] = !isOpen(run)
    }

    func isShowingAll(_ run: SessionStepRun) -> Bool { shownAll.contains(run.id) }

    func toggleShowAll(_ run: SessionStepRun) {
        if !shownAll.insert(run.id).inserted { shownAll.remove(run.id) }
    }

    /// 열린 묶음 안에서 보이는 줄 (전부 펴지 않았으면 최근 `visibleRecent`개: 앞쪽을 가린다)
    func visibleSteps(_ run: SessionStepRun) -> [String] {
        isShowingAll(run) || run.stepIDs.count <= SessionTimeline.visibleRecent ? run.stepIDs : Array(run.stepIDs.suffix(SessionTimeline.visibleRecent))
    }

    /// 가려진 줄이 있다 (Show all이 보인다)
    func hidesSteps(_ run: SessionStepRun) -> Bool { !isShowingAll(run) && run.stepIDs.count > SessionTimeline.visibleRecent }

    func isOpen(step id: String) -> Bool { openSteps.contains(id) }

    /// 줄을 누른다: 닫혀 있으면 열고 본문을 읽는다 (읽기는 밖에서). 이미 읽은 본문은 다시 읽지 않는다
    func toggle(step id: String, load: @escaping (String) async -> ClaudeAppToolDetail?) {
        if openSteps.remove(id) != nil { return }
        openSteps.insert(id)
        guard details[id] == nil else { return }
        details[id] = .loading
        remember(id)
        Task { [weak self] in
            let found = await load(id)
            guard let self, self.openSteps.contains(id) || self.details[id] == .loading else { return }
            self.details[id] = found.map(Detail.loaded) ?? Detail.none
        }
    }

    private func remember(_ id: String) {
        detailOrder.append(id)
        if detailOrder.count > Self.maxDetails {
            let old = detailOrder.removeFirst()
            details[old] = nil
            openSteps.remove(old)
        }
    }
}

/// 단계 한 줄 · 묶음 머리의 한 줄 (E2): 높이 24 · 패딩 3/6 · 왼쪽 −6(호버 판이 글 왼쪽으로 6 번진다) · 글 13/18 `text/secondary` · 호버 `bg/selected` + `text/primary`.
/// chevron 12는 글 끝(호버 · 포커스 · 열림에서 보이고 열리면 90°). Failed는 글 끝에서 8 · 13/18 600 `text/primary` (빨강 없음)
struct SessionStepRowView: View {
    let line: String
    var failed = false
    /// 누를 수 있나 (펼칠 본문이 있거나 묶음 머리)
    var expandable = false
    var isOpen = false
    /// 열린 묶음의 머리는 `text/primary`로 열림을 말한다
    var emphasized = false
    /// 묶음 머리는 접혀 있어도 chevron이 보인다 (승인된 v2 그림: 접힌 묶음이 눌러 펴는 줄임을 알린다). 일반 줄은 호버 · 포커스 · 열림에서만
    var showsChevronAtRest = false
    var accessibilityName: String?
    var onToggle: () -> Void = {}
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let row = HStack(spacing: TFSpace.xs) {
            Text(line)
                .font(TFFont.footnote)
                .tracking(-0.08)
                .foregroundStyle(hovering || emphasized || isOpen ? TFColor.textPrimary : TFColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if expandable {
                TFIcon.disclosureClosed.image(size: 12)
                    .foregroundStyle(TFColor.textSecondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(hovering || focused || isOpen || showsChevronAtRest ? 1 : 0)
                    .animation(TFMotion.ease(TFMotion.disclosureFlip), value: isOpen)
            }
            if failed {
                Text(SessionViewCopy.failed)
                    .font(TFFont.footnoteEmphasis)
                    .tracking(-0.08)
                    .foregroundStyle(TFColor.textPrimary)
                    .padding(.leading, TFSpace.xs)
                    .fixedSize()
            }
        }
        .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
        .frame(height: 24)
        .background(hovering && expandable ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
        .padding(.leading, -6)
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        if expandable {
            Button(action: onToggle) { row }
                .buttonStyle(.plain)
                .focused($focused)
                .onHover { hovering = $0 }
                .overlay(alignment: .leading) {
                    if focused { RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous).strokeBorder(TFColor.borderAccent, lineWidth: 2).padding(.leading, -6) }
                }
                .accessibilityLabel(accessibilityName ?? line)
                .accessibilityValue(failed ? SessionViewCopy.failed : "")
                .accessibilityAddTraits(.isButton)
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(failed ? "\(line), \(SessionViewCopy.failed)" : line)
        }
    }
}

/// 펼친 줄의 본문 (E4): Input · Result 두 코드 블록 (각 16 KiB, 결과가 아직 기록에 없으면 Result 블록이 없다). 줄 밑 4 · 블록 사이 8 · 아래 8
struct SessionStepDetailView: View {
    let detail: ClaudeAppToolDetail

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            if !detail.input.isEmpty { SessionCodeBlockView(label: SessionViewCopy.input, text: detail.input) }
            if let result = detail.result, !result.isEmpty { SessionCodeBlockView(label: SessionViewCopy.result, text: result) }
        }
        .padding(EdgeInsets(top: TFSpace.xs, leading: 0, bottom: TFSpace.sm, trailing: 0))
    }
}

/// 답 밑 한 줄 (E5): 왼쪽 "Worked for 4m 12s"(13/18 숫자 고정폭), 오른쪽 복사 아이콘(답 위 호버 · 포커스에서만). 높이 28은 늘 잡혀 있다
struct SessionFooterView: View {
    let footer: SessionFooter
    /// 복사 아이콘을 보이나 (마우스가 이 답 위에 있다)
    var revealed = false
    /// 시간을 보이나 (Assistant 창은 복사만)
    var showsTime = true
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            if showsTime, let line = SessionTime.workedLine(footer.workedFor) {
                Text(line)
                    .font(TFFont.footnote)
                    .tracking(-0.08)
                    .monospacedDigit()
                    .foregroundStyle(TFColor.textSecondary)
            }
            Spacer(minLength: 0)
            if let copy = footer.copyText {
                SessionCopyButton(text: copy, alwaysVisible: false, revealed: revealed)
                    .padding(.trailing, -7)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}

/// 도는 턴의 시계 줄 (E6): "Working · m:ss"가 초마다 올라간다 (말뿐: 아이콘 · 스피너 · 색 없음). 접근성은 초마다 읽지 않고 "Working"만
struct SessionClockView: View {
    let clock: SessionClock

    var body: some View {
        TimelineView(.periodic(from: clock.since, by: 1)) { context in
            Text(SessionTime.workingLine(context.date.timeIntervalSince(clock.since)))
                .font(TFFont.footnote)
                .tracking(-0.08)
                .monospacedDigit()
                .foregroundStyle(TFColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SessionViewCopy.working)
    }
}
#endif
