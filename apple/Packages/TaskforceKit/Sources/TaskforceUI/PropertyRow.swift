import SwiftUI

/// PropertyRow (0.2.0 디자인 시스템 Molecules, OA U2): 이슈의 속성 하나, Notion식. 조용한 라벨(footnote `text/secondary`, 폭 84 고정) + 값(footnote `text/primary`, 한 줄 끝 줄임).
/// 값 앞에 선택 아이콘(StatusMark · ProjectIcon). 안쪽 4/10 · 모서리 6 · 최소 높이 26 · 간격 6.
/// **값이 있는 속성만 그린다** (그리는 쪽 몫: "None"이나 빈 칸을 찍지 않는다). U2의 속성은 읽기 전용이라 글이다 (편집 입구는 후속).
/// 접근성 이름 "{label}: {value}". 기한이 지났으면 값이 `status/overdue` 600이고 이름에 ", overdue"가 붙는다
public struct PropertyRow<Icon: View>: View {
    nonisolated public static var labelWidth: CGFloat { 84 }

    let label: String
    let value: String
    let overdue: Bool
    let icon: Icon

    public init(label: String, value: String, overdue: Bool = false, @ViewBuilder icon: () -> Icon) {
        self.label = label
        self.value = value
        self.overdue = overdue
        self.icon = icon()
    }

    /// "{label}: {value}" (지났으면 ", overdue")
    nonisolated public static func accessibilityName(label: String, value: String, overdue: Bool = false) -> String {
        "\(label): \(value)" + (overdue ? ", overdue" : "")
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(TFFont.footnote)
                .tracking(-0.08)
                .foregroundStyle(TFColor.textSecondary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            HStack(spacing: 6) {
                icon
                Text(value)
                    .font(overdue ? TFFont.footnoteEmphasis : TFFont.footnote)
                    .tracking(-0.08)
                    .foregroundStyle(overdue ? TFColor.statusOverdue : TFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .frame(minHeight: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityName(label: label, value: value, overdue: overdue))
    }
}

extension PropertyRow where Icon == EmptyView {
    public init(label: String, value: String, overdue: Bool = false) {
        self.init(label: label, value: value, overdue: overdue, icon: { EmptyView() })
    }
}

#Preview("Property rows") {
    VStack(spacing: 0) {
        PropertyRow(label: "Status", value: "In Progress") { StatusMark(.inProgress) }
        PropertyRow(label: "Due", value: "Thu")
        PropertyRow(label: "Due", value: "Yesterday", overdue: true)
        PropertyRow(label: "Project", value: "Taskforce 0.2.0, Shape launch, Hiring: founding designer, October investor update") { ProjectGlyph(.rocket) }
    }
    .padding(8)
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
