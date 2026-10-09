import SwiftUI

/// Card (0.2.0 디자인 시스템 Molecules): 패널 안의 상세 한 칸. `bg/field` 받침, 모서리 12, 테두리 · 그림자 없음. 카드 안에 카드를 넣지 않는다.
/// 주제 하나: 줄들(안쪽 구분선) 또는 문단 하나. `title`은 12pt 캡션(선택), `action`은 캡션 끝의 작은 컨트롤 하나(예: ReturnSummary의 Clear).
/// 카드 위의 보조 글은 `text/secondary-selected`로 올려 대비를 지킨다.
public struct Card<Content: View, Action: View>: View {
    let title: String?
    let action: Action
    let content: Content

    public init(title: String? = nil, @ViewBuilder action: () -> Action, @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action()
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        let tray = VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: TFSpace.sm) {
                    Text(title)
                        .font(TFFont.caption)
                        .foregroundStyle(TFColor.textSecondarySelected)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    action
                }
                .frame(minHeight: 16)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 12))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgField, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        // 캡션이 있는 카드만 그 이름으로 묶는다 (캡션 없는 카드에 빈 이름을 붙이지 않는다)
        if let title {
            tray.accessibilityLabel(title)
        } else {
            tray
        }
    }
}

extension Card where Action == EmptyView {
    public init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, action: { EmptyView() }, content: content)
    }
}

/// 카드 안 문단 하나 (12pt 안쪽 여백, 캡션 바로 아래면 위 4)
public struct CardText: View {
    let text: String
    let afterTitle: Bool

    public init(_ text: String, afterTitle: Bool = false) {
        self.text = text
        self.afterTitle = afterTitle
    }

    public var body: some View {
        Text(text)
            .font(TFFont.callout)
            .foregroundStyle(TFColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: afterTitle ? 4 : 12, leading: 12, bottom: 12, trailing: 12))
    }
}

#Preview("Card") {
    VStack(spacing: 8) {
        Card(title: "Why this project") { CardText("Same Notion database as the other launch notes.", afterTitle: true) }
        Card { CardText("One paragraph without a caption.") }
    }
    .padding()
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
