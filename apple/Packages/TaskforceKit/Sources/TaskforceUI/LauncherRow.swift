import SwiftUI
import TaskforceKit

/// Launcher row (Figma 5:52, Mac): 제목 + 오른쪽에 기한 하나. 기한 지남 · 오늘은 빨강 (L2).
/// 선택 행만 bg/selected + return 키캡. 부제는 기본으로 끈다 (L4). 높이 40.
/// 오늘 끝낸 할 일(`dimmed`)은 제목을 text/secondary로 흐리게 (취소선 없음).
/// `checked`: 고르는 목록의 지금 값 (⌘K Status의 지금 상태). 오른쪽에 체크, 골라도 return 키캡은 없다 (↩가 할 일이 없다).
/// `shortcut`: 그 줄의 단축키 (⌘K Delete의 "⌘⌫"). 늘 보이는 키캡, 고르면 그 오른쪽에 return 키캡.
public struct LauncherRow: View {
    public enum Leading: Sendable, Equatable {
        /// 할 일: 16pt 상태 표시 (`TaskStatusMark`)
        case status(TaskStatusMark.State)
        /// 명령 · 묻기 등: SF Symbol (Figma에 없는 행이라 같은 크기 · 색으로 구성)
        case symbol(String)
        /// 원문 고르기: 출처 로고 (Source icon S)
        case source(SourceService)
        /// Sign in with Google: 표준 색 G를 흰 원 위에 (Google 브랜드 규칙: 흰 바탕)
        case google
    }

    let title: String
    let subtitle: String?
    let accessory: String?
    let urgent: Bool
    let selected: Bool
    let dimmed: Bool
    let checked: Bool
    let shortcut: String?
    let leading: Leading
    let onMark: (() -> Void)?

    /// `onMark`: 상태 표시를 누르면 (To Do · In Progress는 완료, Done은 다시 열기)
    public init(
        title: String,
        subtitle: String? = nil,
        accessory: String? = nil,
        urgent: Bool = false,
        selected: Bool = false,
        dimmed: Bool = false,
        checked: Bool = false,
        shortcut: String? = nil,
        leading: Leading = .status(.toDo),
        onMark: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.urgent = urgent
        self.selected = selected
        self.dimmed = dimmed
        self.checked = checked
        self.shortcut = shortcut
        self.leading = leading
        self.onMark = onMark
    }

    public var body: some View {
        HStack(spacing: TFSpace.md) {
            leadingView
                .frame(width: 16, height: 16)
            TitleSubtitleLayout(maxTitleWidth: 400, spacing: TFSpace.sm) {
                Text(title)
                    .font(TFFont.callout)
                    .foregroundStyle(dimmed ? TFColor.textSecondary : TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(TFFont.footnote)
                        .foregroundStyle(TFColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let accessory {
                Text(accessory)
                    .font(TFFont.footnote)
                    .foregroundStyle(urgent ? TFColor.statusOverdue : TFColor.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
                    .fixedSize()
            }
            if let shortcut {
                Keycap(shortcut)
            }
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(minWidth: 20, minHeight: 20)
            } else if selected {
                Keycap(systemImage: "return")
            }
        }
        .padding(.horizontal, TFSpace.md)
        .frame(height: 40)
        .background(selected ? TFColor.bgSelected : .clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected || checked ? .isSelected : [])
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .status(let state):
            TaskStatusMark(state, size: 16, action: onMark)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? TFColor.textAccent : TFColor.textSecondary)
        case .source(let service):
            SourceIcon(service, size: .s)
        case .google:
            TFImage.googleG
                .resizable()
                .frame(width: 12, height: 12)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white))
        }
    }
}

/// 제목은 최대 400까지 제 폭만, 부제는 남는 폭 (L1: 긴 제목이 부제를 한 글자로 자르지 않게)
struct TitleSubtitleLayout: Layout {
    let maxTitleWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(width: proposal.width ?? .infinity, subviews: subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: frames.last.map { $0.maxX } ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = place(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: frame.width, height: bounds.height)
            )
        }
    }

    private func place(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard let title = subviews.first else { return [] }
        let ideal = title.sizeThatFits(.unspecified).width
        let titleWidth = min(ideal, maxTitleWidth, width)
        var frames = [CGRect(x: 0, y: 0, width: titleWidth, height: 0)]
        if subviews.count > 1 {
            let x = titleWidth + spacing
            let subtitleIdeal = subviews[1].sizeThatFits(.unspecified).width
            frames.append(CGRect(x: x, y: 0, width: max(0, min(subtitleIdeal, width - x)), height: 0))
        }
        return frames
    }
}

/// 런처의 구역 제목 ("Review" · "In Progress" · "To Do" · "Done Today" · "Commands")
public struct LauncherSectionLabel: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(TFFont.caption)
            .foregroundStyle(TFColor.textSecondary)
            .padding(.leading, TFSpace.md)
            .padding(.top, TFSpace.sm)
            .padding(.bottom, TFSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Launcher row") {
    VStack(spacing: 0) {
        LauncherSectionLabel("Review")
        LauncherRow(title: "법무팀에 계약서 초안 전달", accessory: "Fri", leading: .status(.review))
        LauncherSectionLabel("In Progress")
        LauncherRow(title: "투자사 IR 자료 업데이트", accessory: "Overdue", urgent: true, leading: .status(.inProgress)) {}
        LauncherSectionLabel("To Do")
        LauncherRow(title: "제안서 보내기", accessory: "Today", urgent: true, selected: true) {}
        LauncherRow(title: "계약서 검토 의견 전달", accessory: "Wed") {}
        LauncherRow(
            title: "An extremely long launcher row title that keeps going and going well past four hundred points wide",
            subtitle: "Sequoia · Weekly sync",
            accessory: "Sep 30"
        )
        LauncherSectionLabel("Done Today")
        LauncherRow(title: "주간 회의록 정리", dimmed: true, leading: .status(.done)) {}
        LauncherSectionLabel("Status")
        LauncherRow(title: "To Do", leading: .status(.toDo))
        LauncherRow(title: "In Progress", selected: true, checked: true, leading: .status(.inProgress))
        LauncherRow(title: "Done", leading: .status(.done))
        LauncherSectionLabel("Actions")
        LauncherRow(title: "Open source", leading: .symbol("arrow.up.right.square"))
        LauncherRow(title: "Delete", selected: true, shortcut: "⌘⌫", leading: .symbol("trash"))
        LauncherSectionLabel("Commands")
        LauncherRow(title: "Send clipboard as source", leading: .symbol("doc.on.clipboard"))
        LauncherRow(title: "Ask “when is the IR deck due?”", selected: true, leading: .symbol("sparkle"))
    }
    .padding(8)
    .frame(width: 696)
}
