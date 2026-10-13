#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Review 페이지의 머리 (디자인 PanelHeader): 제목 = 보이는 결정의 항목 이름(한 줄, 넘치면 …), 둘 이상이면 단계 점 (6pt 점, 24pt 누르는 영역, ← →).
/// 단계 점은 render 때의 id 목록을 들고 있다: 누른 점은 큐가 그사이 바뀌었어도 그 점이 가리키던 항목으로 간다. 닫기 버튼은 없다
struct ReviewPanelHeader: View {
    let shell: EdgeShellModel

    var body: some View {
        let queue = shell.reviewQueue
        let ids = queue.ids
        let shown = shell.shownReview
        PanelHeader(
            title: shown?.title ?? shell.view.title,
            steps: shown.flatMap { queue.index(of: $0.id) }.map { PanelHeader.Steps(count: queue.count, current: $0) },
            onStep: { index in
                guard ids.indices.contains(index) else { return }
                shell.openReview(itemID: ids[index])
            }
        )
        // 제목은 한 줄에서 잘린다: 전체 제목은 도움말로
        .help(shown?.title ?? "")
    }
}

/// Review 페이지의 본문: DecisionBlock 하나 (질문 · 원문 · 번호 붙은 답), 또는 읽는 중 · 오프라인 · 읽기 실패 · "No decisions waiting".
/// 이 화면을 여는 것 · 읽는 것 · 단계를 옮기는 것은 어떤 답도 아니다. 답은 사용자가 고른 것(클릭 · 1/2 키)만 보낸다 (`EdgeShellModel.answer`).
struct ReviewPanelBody: View {
    let shell: EdgeShellModel
    let desk: ReviewDesk
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch shell.reviewScreen {
            case .blank:
                // 읽는 중: 아무 주장도 하지 않는다
                Color.clear.frame(height: 0)
            case .offline:
                PanelEmptyState(.offline) { tryAgain(.md) }
            case .failed:
                PanelEmptyState(.couldNotLoad) { tryAgain(.md) }
            case .empty(let problem):
                if let problem { problemNotice(problem) }
                goneNotice
                PanelEmptyState(.noDecisions) {
                    Button("All work") { shell.openAllWork() }.buttonStyle(TFButtonStyle(.secondary, size: .md))
                }
            case .decision(let problem):
                if let problem { problemNotice(problem) }
                goneNotice
                if let action = shell.shownReview {
                    decision(action)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 결정

    private func decision(_ action: ActionSummary) -> some View {
        let id = action.id
        let presentation = shell.reviewPresentation
        let canAnswer = shell.reviewScreen.canAnswer
        let sending = desk.sending[id]
        let memberships = shell.contexts?.index.memberships(of: id) ?? .unknown
        let today = DueDateFormat.today()
        // 질문이 확인 이유뿐이라(바뀐 사실이 아니다) 결정의 대상 · 값이 사라지지 않게: 머리에서 잘린 전체 제목, 확인할 기한 (`Due Fri`)
        var facts: [DecisionBlock<ReviewSourceView>.Fact] = []
        if ReviewHeaderFit.truncates(action.title, steps: shell.reviewQueue.count) { facts.append(.init(action.title, .subject)) }
        if let due = ReviewCopy.due(action, today: today) {
            facts.append(.init(due, DueText.isUrgent(due: action.dueDate, reasons: [], today: today) ? .urgent : .value))
        }
        let answers = ReviewAnswer.allCases.map { answer in
            DecisionBlock<ReviewSourceView>.Answer(
                index: answer.key, label: answer.label,
                phase: sending == answer ? .sending : (sending != nil || !canAnswer ? .locked : .ready)
            )
        }
        return DecisionBlock(
            meta: ReviewCopy.meta(memberships: memberships), question: ReviewCopy.question(action), facts: facts, answers: answers,
            note: desk.notice.flatMap { $0.id == id ? $0.text : nil },
            // 누른 답은 render 때의 id(`id`)에만 간다: 큐가 바뀌어 다른 항목이 이 자리에 와도 그 항목에 가지 않는다
            onAnswer: { key in
                guard let answer = ReviewAnswer(key: key) else { return }
                shell.answer(answer, for: id)
            }
        ) {
            ReviewSourceView(
                source: desk.source(for: id), open: { openURL($0) },
                retry: { Task { await desk.retrySource(for: action, presentation: presentation) } }
            )
        }
        // 이 항목의 근거를 확인한다 (읽기일 뿐 해결이 아니다). 항목이 달라지거나(`last_activity_at`) 이 페이지에 다시 들어오면 다시
        .task(id: SourceKey(id: id, activity: action.lastActivityAt, presentation: presentation)) {
            await desk.loadSource(for: action, presentation: presentation)
        }
        .id(id)
    }

    private struct SourceKey: Hashable {
        let id: UUID
        let activity: Date
        let presentation: Int
    }

    // MARK: 안내

    /// 결과를 확인하지 못했거나 거절된 답의 안내가 그 항목이 큐에서 사라진 뒤에도 남는다: 사라졌다는 사실이 성공 증거가 아니다
    @ViewBuilder
    private var goneNotice: some View {
        if let notice = desk.notice, !shell.reviewQueue.contains(notice.id) {
            Notice(icon: .paused, title: notice.text)
                .padding(.bottom, TFSpace.sm)
        }
    }

    private func problemNotice(_ problem: WorkLoad.Problem) -> some View {
        Notice(title: problem == .offline ? PanelEmptyKind.offline.title : PanelEmptyKind.couldNotLoad.title) {
            tryAgain(.sm)
        }
        .padding(.bottom, TFSpace.sm)
    }

    private func tryAgain(_ size: TFButtonStyle.Size) -> some View {
        Button(ReviewCopy.tryAgain) { shell.onRetry() }.buttonStyle(TFButtonStyle(.secondary, size: size))
    }
}

/// 결정 아래 원문 (디자인 SourceQuote): 기존 근거를 사실대로. 읽는 중 · 읽지 못함 · 근거 없음 · Slack 연결을 끊어 지운 인용은 각각 다르게 말한다
struct ReviewSourceView: View {
    let source: ReviewSource
    let open: (URL) -> Void
    let retry: () -> Void

    var body: some View {
        switch source {
        case .loading:
            Color.clear.frame(height: 0)
        case .failed:
            status(ReviewCopy.couldNotLoadSource) {
                Button(ReviewCopy.tryAgain, action: retry).buttonStyle(TFButtonStyle(.secondary, size: .sm))
            }
        case .noQuote:
            status(ReviewCopy.noQuote)
        case .lines(let lines):
            VStack(spacing: 6) {
                ForEach(lines) { line in
                    if line.removed {
                        status(RemovedQuote.label)
                    } else {
                        SourceQuote(
                            service: line.service, place: line.place, time: line.time.map { WhenText.label($0) }, text: line.text,
                            openTitle: line.url == nil ? nil : line.service.openTitle, onOpen: line.url.map { url in { open(url) } }
                        )
                    }
                }
            }
        }
    }

    /// 인용이 아닌 사실 한 줄 (밑줄도 인용 부호도 없다)
    private func status<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        return HStack(spacing: TFSpace.sm) {
            Text(text)
                .font(TFFont.callout)
                .foregroundStyle(TFColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(EdgeInsets(top: 10, leading: TFSpace.md, bottom: 10, trailing: TFSpace.md))
        .background(TFColor.bgField, in: shape)
        .accessibilityElement(children: .combine)
    }
}

/// 머리 제목이 한 줄에 다 들어가는가 (디자인 PanelHeader: 앞 16 · 뒤 10, 단계 점은 둘 이상일 때 24pt씩, 사이 4, 제목은 callout-strong 15 semibold).
/// 넘치면 머리는 …로 줄이므로, 결정의 대상이 가려지지 않게 본문에 전체 제목을 한 줄 더한다
enum ReviewHeaderFit {
    static func truncates(_ title: String, steps: Int) -> Bool {
        let stepsWidth = steps > 1 ? CGFloat(steps) * 24 + 4 : 0
        let available = EdgePanelMetrics.width - 16 - 10 - stepsWidth
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let width = (title as NSString).size(withAttributes: [.font: font, .kern: -0.24]).width
        // 글자 폭 측정과 SwiftUI의 배치가 1~2pt 어긋날 수 있다: 가장자리에서는 더하는 쪽으로
        return width > available - 6
    }
}

/// Review 페이지의 키 (디자인 Focus and keys · EdgeRail "Click a Needs-you ring: … ⌘1 opens the newest"): ← → 단계, 1 · 2 답.
/// **텍스트 편집 밖에서만** 듣는다 (`isTextEditing`: Chats 입력칸 · IME 조합 중 · 검색 · 편집 칸이 먼저). 수식키가 붙은 키는 지나간다.
/// 3은 답이 없다 (v1에는 세 번째 행동이 없다): 지나간다
enum ReviewKey: Equatable {
    case previous, next
    case answer(ReviewAnswer)
}

enum EdgeReviewKeys {
    /// 키 이벤트 → Review 키. `characters`는 레이아웃을 따른다 (AZERTY처럼 1이 Shift 조합인 배열도 맞는다)
    static func of(keyCode: Int, characters: String?, flags: NSEvent.ModifierFlags) -> ReviewKey? {
        // 방향키는 `.numericPad` · `.function`이 함께 온다
        let flags = flags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch keyCode {
        case kVK_LeftArrow where flags.isEmpty: return .previous
        case kVK_RightArrow where flags.isEmpty: return .next
        default: break
        }
        guard flags.isEmpty || flags == .shift, let characters, characters.count == 1, let number = Int(characters),
              let answer = ReviewAnswer(key: number) else { return nil }
        return .answer(answer)
    }

    /// 지금 글을 편집하는 중인가: 편집할 수 있는 텍스트(필드 에디터 포함) 또는 IME 조합 중인 입력. 읽기 전용으로 고른 글은 편집이 아니다
    @MainActor
    static func isTextEditing(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSText, text.isEditable || text.isFieldEditor { return true }
        if let client = responder as? NSTextInputClient, client.hasMarkedText() { return true }
        return false
    }
}
#endif
