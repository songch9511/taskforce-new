import SwiftUI
import TaskforceKit

/// Task row (Figma 156:6 P1 190:3818 · P11 292:2907, iPhone): 옅은 빈 원 + 제목(2줄까지) + 오른쪽 기한 + 바뀜 점.
/// - 원: 열린 할 일(To Do · In Progress 모두)은 옅은 빈 원, 누르면 Done. 오늘 끝낸 할 일은 검은 체크 원, 누르면 끝내기 전 상태로.
///   `onToggle`이 없으면 누를 수 없다 (저장본 · 오프라인). 누르는 영역은 44×44 (보이는 원은 22).
/// - 기한: 지났거나 오늘(`urgent`)이면 status/overdue. 끝낸 할 일 제목은 보조 색(취소선 없음).
/// - 바뀜 점: 마지막으로 본 뒤 바뀜 (`SeenTracker.showsDot`) → 6pt Ink 점 (Mac 목록 행과 같은 점)
/// - 큰 글자(접근성 크기, P11): 제목은 자르지 않고 기한은 제목 아래, 원은 44
/// - `Waiting on …` 줄은 U5가 제목 아래에 더한다. 펼친 근거는 `detail` (부르는 쪽이 넣는다)
/// VoiceOver: 원은 버튼 `markLabel`("Mark Done"), 글자는 한 요소 "제목, 기한[, Changed]"(누르면 `onOpen`).
public struct TaskRow<Detail: View>: View {
    let title: String
    let due: String?
    let urgent: Bool
    let done: Bool
    let changed: Bool
    let markLabel: String
    let onToggle: (() -> Void)?
    let onOpen: (() -> Void)?
    let openLabel: String?
    let detail: Detail

    @Environment(\.dynamicTypeSize) private var typeSize
    /// 원의 가운데를 제목 첫 줄 글자 가운데에 맞춘다 (기준선에서 대문자 높이의 반쯤 위)
    @ScaledMetric(relativeTo: .body) private var markBaselineOffset: CGFloat = 6
    /// 바뀜 점 6 (글자와 함께 커진다)
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 6

    public init(
        title: String, due: String?, urgent: Bool = false, done: Bool = false, changed: Bool = false,
        markLabel: String = "Mark Done", onToggle: (() -> Void)?, onOpen: (() -> Void)? = nil, openLabel: String? = nil,
        @ViewBuilder detail: () -> Detail
    ) {
        self.title = title
        self.due = due
        self.urgent = urgent
        self.done = done
        self.changed = changed
        self.markLabel = markLabel
        self.onToggle = onToggle
        self.onOpen = onOpen
        self.openLabel = openLabel
        self.detail = detail()
    }

    private var isLarge: Bool { typeSize.isAccessibilitySize }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            mark
            VStack(alignment: .leading, spacing: TFSpace.sm) {
                text
                detail
            }
            .padding(.vertical, TFSpace.md)
            // 보이는 원과 제목 사이 12 (큰 글자 16, P11): 누르는 칸이 원 오른쪽으로 11 더 있다
            .padding(.leading, isLarge ? TFSpace.lg - 11 : 1)
            // 누르는 곳은 원 오른쪽 행 전체 (위아래 여백 포함, 44 이상). 펼친 원문은 자기 누르기(원문 열기)가 먼저
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
        }
    }

    // MARK: 원

    /// 보이는 원 22 (큰 글자 44), 누르는 칸은 늘 44 이상
    private var markSize: CGFloat { isLarge ? 44 : 22 }

    @ViewBuilder
    private var mark: some View {
        let shape = Group {
            if done {
                TaskStatusMark(.done, size: markSize)
            } else {
                Circle()
                    .strokeBorder(TFColor.borderControl, lineWidth: isLarge ? 3 : 1.5)
                    .opacity(TaskRowMetrics.openMarkOpacity)
                    .frame(width: markSize, height: markSize)
            }
        }
        .accessibilityHidden(true)
        // 목록 구분선은 원의 왼쪽 끝에서 시작한다 (Figma 구분선 = 내용 폭)
        #if os(iOS)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        #endif
        // 누르는 칸: 원 양옆 11씩 더 (보이는 원 22 → 44×44, 큰 글자 44 → 66×44). 부르는 쪽은 행 왼쪽 여백을 11 줄인다
        let hitWidth = markSize + 22
        let hitHeight = max(44, markSize)
        Group {
            if let onToggle {
                Button(action: onToggle) {
                    shape
                        .frame(width: hitWidth, height: hitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(markLabel)
            } else {
                shape
                    .frame(width: hitWidth, height: hitHeight)
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + markBaselineOffset }
    }

    // MARK: 제목 · 기한

    @ViewBuilder
    private var text: some View {
        let group = Group {
            if isLarge {
                // P11: 제목 전부, 기한은 아래
                VStack(alignment: .leading, spacing: TFSpace.xs) {
                    titleText
                    if due != nil || changed {
                        HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) { trailing }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) {
                    titleText.lineLimit(2)
                    trailing
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, due, changed ? "Changed" : nil].compactMap { $0 }.joined(separator: ", "))
        if let onOpen {
            group
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(openLabel ?? "")
                .accessibilityAction { onOpen() }
        } else {
            group
        }
    }

    private var titleText: some View {
        Text(title)
            .font(TFFont.body)
            .foregroundStyle(done ? TFColor.textSecondary : TFColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var trailing: some View {
        if let due {
            Text(due)
                .font(TFFont.callout)
                .foregroundStyle(urgent && !done ? TFColor.statusOverdue : TFColor.textSecondary)
                .fixedSize(horizontal: !isLarge, vertical: true)
        }
        if changed {
            Circle()
                .fill(TFColor.textPrimary)
                .frame(width: dotSize, height: dotSize)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + markBaselineOffset / 1.5 }
        }
    }
}

/// 열린 할 일의 옅은 원: border/control에 이 불투명도. Figma P1은 0.55(Light 2.3:1 · Dark 2.8:1)인데,
/// 누를 수 있는 표시라 WCAG 비문자 대비 3:1을 지키는 값으로 올렸다 (Light 3.1:1 · Dark 4.0:1, TaskforceUITests `ContrastTests`)
enum TaskRowMetrics {
    static let openMarkOpacity = 0.7
}

extension TaskRow where Detail == EmptyView {
    public init(
        title: String, due: String?, urgent: Bool = false, done: Bool = false, changed: Bool = false,
        markLabel: String = "Mark Done", onToggle: (() -> Void)?, onOpen: (() -> Void)? = nil, openLabel: String? = nil
    ) {
        self.init(
            title: title, due: due, urgent: urgent, done: done, changed: changed, markLabel: markLabel,
            onToggle: onToggle, onOpen: onOpen, openLabel: openLabel
        ) { EmptyView() }
    }
}

#Preview("Task row") {
    List {
        TaskRow(title: "금요일 고객 데모 준비 (새 온보딩, 결제 화면 포함)", due: "Fri", onToggle: {})
        TaskRow(title: "온보딩 디자인 시안", due: "Today", urgent: true, onToggle: {})
        TaskRow(title: "지훈에게 디자인 인계", due: "Fri", changed: true, onToggle: {})
        TaskRow(title: "해외 파트너 요구사항을 반영한 다음 주 경영진 리뷰 발표 자료 정리와 공유", due: "Tue", onToggle: nil)
        TaskRow(title: "주간 회의록 정리", due: "Today", done: true, markLabel: "Mark To Do", onToggle: {})
        TaskRow(title: "기한이 없는 할 일", due: nil, onToggle: {})
    }
    .listStyle(.plain)
}
