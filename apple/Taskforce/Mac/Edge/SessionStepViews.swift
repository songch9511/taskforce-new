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
    /// 시작 알림을 낸 시계 줄의 id (턴마다 하나): 줄이 다시 만들어져도(스크롤 · 다시 그림) 같은 시계는 되풀이해 알리지 않는다. 세션을 바꾸면 비운다
    @ObservationIgnored private var announcedClocks: Set<String> = []

    /// 이 시계를 처음 알리는가 (처음이면 true: 알렸다고 적는다). VoiceOver가 같은 "Working"을 줄이 다시 만들어질 때마다 읽지 않게 한다
    func announceClock(_ id: String) -> Bool { announcedClocks.insert(id).inserted }

    // MARK: 그리는 창
    // 본문은 즉시 쌓기라 긴 대화를 한꺼번에 그리면 첫 배치가 줄 수에 비례해 몇 초씩 걸린다. 처음엔 가장 새 `SessionTimeline.renderWindow`(150)줄만 그리고, 위의 "Show earlier"가 150줄씩 더 편다.

    /// 창이 바뀐 횟수 (읽어 두면 폈을 때 본문이 다시 그려진다)
    private(set) var windowRevision = 0
    /// 읽어 둔 줄을 모두 폈다 (그 뒤로는 창이 없다: 앞 쪽 기록을 읽어 앞에 붙은 줄도 그대로 보인다)
    private(set) var showsAllEntries = false
    /// 지금 그리는 첫 줄의 id. **새 줄이 붙어도 이 자리를 지킨다**: 가장 새 150줄을 매번 새로 정하면 위의 줄이 하나씩 사라져 위로 거슬러 읽는 글이 밀린다 (대화 상태가 위쪽 줄을 안 버리는 것과 같은 까닭).
    /// 이 줄이 대화에서 사라지면(대화가 오래된 줄을 버렸다) 다시 가장 새 150줄로 정한다
    @ObservationIgnored private var windowCutID: String?
    /// 폈을 때 스크롤을 붙잡을 줄: 펴기 전의 첫 줄 (패널이 `onChange`에서 한 번 가져간다)
    @ObservationIgnored private var pendingScrollAnchor: String?

    /// 그릴 첫 줄의 자리 (0이면 전부). 본문을 계산하는 동안 불러도 된다 (관찰하지 않는 기억만 바꾼다)
    func windowStart(in entries: [SessionEntry]) -> Int {
        _ = windowRevision
        if showsAllEntries { return 0 }
        if let id = windowCutID, let at = entries.firstIndex(where: { $0.id == id }) { return at }
        let start = SessionTimeline.windowStart(entries, limit: SessionTimeline.renderWindow)
        // 처음부터 창에 다 드는 대화도 첫 줄에 붙들어 둔다: 길어져도 앞이 잘리지 않는다
        windowCutID = entries.indices.contains(start) ? entries[start].id : nil
        return start
    }

    /// "Show earlier": 창을 150줄 앞으로 넓힌다 (덩어리 첫 줄로 맞춘다). 처음까지 닿으면 전부 편다. 펴기 전의 첫 줄을 스크롤이 붙잡도록 적어 둔다
    func revealEarlier(in entries: [SessionEntry]) {
        let current = windowStart(in: entries)
        guard current > 0, entries.indices.contains(current) else {
            revealAll()
            return
        }
        pendingScrollAnchor = entries[current].id
        let start = SessionTimeline.unitStart(entries, atOrBefore: current - SessionTimeline.renderWindow)
        if start > 0 {
            windowCutID = entries[start].id
        } else {
            showsAllEntries = true
            windowCutID = nil
        }
        windowRevision += 1
    }

    /// 읽어 둔 줄을 모두 편다 (앞 쪽 기록을 읽기 직전에도: 읽어서 앞에 붙은 줄이 창 밖에 숨지 않게)
    func revealAll() {
        showsAllEntries = true
        windowCutID = nil
        windowRevision += 1
    }

    /// 폈을 때 붙잡을 줄 (한 번만 돌려준다)
    func takeScrollAnchor() -> String? {
        defer { pendingScrollAnchor = nil }
        return pendingScrollAnchor
    }

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

    /// 줄을 누른다: 닫혀 있으면 열고 본문을 읽는다 (읽기는 밖에서). **완성된 본문(결과가 있다)만** 다시 읽지 않는다.
    /// 읽지 못한 것(`none`)이나 결과가 아직 없던 것(그때 도구가 도는 중이었다)은 담아 두지 않는다: 다시 열면 다시 읽는다 (한 번 실패하면 영영 빈 줄로 남지 않게)
    func toggle(step id: String, load: @escaping (String) async -> ClaudeAppToolDetail?) {
        if openSteps.remove(id) != nil { return }
        openSteps.insert(id)
        if case .loaded(let detail)? = details[id], detail.result != nil { return }
        guard details[id] != .loading else { return }
        if details[id] == nil { remember(id) }
        details[id] = .loading
        Task { [weak self] in
            let found = await load(id)
            guard let self, self.openSteps.contains(id) || self.details[id] == .loading else { return }
            self.details[id] = found.map(Detail.loaded) ?? Detail.none
        }
    }

    /// 다른 세션으로 바뀌었다: 줄 · 묶음 id는 세션 안에서만 겹치지 않는다 (기록 줄 위치 · 서버 글 id). 앞 세션의 열림 · 읽은 본문이 남아 다른 세션의 같은 id에 붙지 않게 모두 비운다
    func reset() {
        chosen = [:]
        shownAll = []
        openSteps = []
        details = [:]
        detailOrder = []
        announcedClocks = []
        hoveredFooter = nil
        showsAllEntries = false
        windowCutID = nil
        pendingScrollAnchor = nil
        windowRevision = 0
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
                // 눌러 펴는 줄은 펼침 상태를 값으로 말한다 (aria-expanded에 해당). 실패는 이름에 붙는다 (값은 펼침 상태 하나만)
                .accessibilityLabel(SessionAccessibility.name(accessibilityName ?? line, failed: failed))
                .accessibilityValue(SessionAccessibility.state(expanded: isOpen))
                .accessibilityAddTraits(.isButton)
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SessionAccessibility.name(line, failed: failed))
        }
    }
}

/// 세션 보기의 접근성 말 (뷰가 그대로 쓴다: 시험이 말을 고정한다). 접힘 · 펼침은 이름이 아니라 **값**이다 (VoiceOver가 "Collapsed" · "Expanded"로 읽는다)
enum SessionAccessibility {
    /// 접힘 · 펼침 값 (묶음 머리 · 눌러 펴는 줄 · 옆줄 띠 · 옆줄)
    static func state(expanded: Bool) -> String { expanded ? SessionViewCopy.expanded : SessionViewCopy.collapsed }

    /// 줄의 이름: 실패한 줄은 이름 끝에 ", Failed"
    static func name(_ line: String, failed: Bool) -> String { failed ? "\(line), \(SessionViewCopy.failed)" : line }
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

/// 턴의 한 줄 (E5, 사용자 결정 2026-10-23): "Worked for 4m 12s"(13/18 숫자 고정폭)는 답 **바로 위**의 캡션 줄(높이 18)이고,
/// 복사 아이콘은 답 **바로 밑**의 줄 오른쪽(답 위 호버 · 포커스에서만, 높이 28은 늘 잡혀 있다)이다. 답 없는 턴의 끝 시간 줄은 28 그대로
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
        .frame(height: footer.aboveAnswer ? 18 : 28)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}

/// 도는 턴의 시계 줄 (E6): "Working · m:ss"가 초마다 올라간다 (말뿐: 아이콘 · 스피너 · 색 없음). 접근성은 초마다 읽지 않고 "Working"만이고 시작할 때 한 번 알린다 (끝은 밑줄의 "Worked for"가 알린다).
/// 알렸는지는 뷰가 아니라 **시계 id**로 `SessionStepsState`가 기억한다: 줄이 다시 만들어져도(스크롤로 사라졌다 돌아옴) 같은 시계를 되풀이해 알리지 않는다
struct SessionClockView: View {
    let clock: SessionClock
    let state: SessionStepsState

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
        .onAppear {
            guard state.announceClock(clock.id) else { return }
            AccessibilityNotification.Announcement(SessionViewCopy.working).post()
        }
    }
}
#endif
