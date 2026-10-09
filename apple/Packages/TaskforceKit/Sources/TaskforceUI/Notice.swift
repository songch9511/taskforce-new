import SwiftUI

/// Notice (0.2.0 디자인 시스템 Molecules): 제품 일부를 막는 상태, 그래도 되는 것, 빠져나가는 길.
/// `bg/elevated` 위 `border/control` 테두리. 색 채움 없음(말이 상태를 전한다). 탭 · 패널 맨 위에 하나까지.
/// 패널 안에서는 제목과 동작만 쓰고 설명은 Settings에만 둔다(`message`는 Settings에서만 넘긴다).
public struct Notice<Actions: View>: View {
    let icon: TFIcon
    let title: String
    let message: String?
    let actions: Actions

    public init(icon: TFIcon = .paused, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.image()
                .foregroundStyle(TFColor.textPrimary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(TFFont.callout)
                        .foregroundStyle(TFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if Actions.self != EmptyView.self {
                    HStack(spacing: TFSpace.sm) { actions }
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(TFSpace.md)
        .background(TFColor.bgElevated, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous).strokeBorder(TFColor.borderControl, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

extension Notice where Actions == EmptyView {
    public init(icon: TFIcon = .paused, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message, actions: { EmptyView() })
    }
}

#Preview("Notice") {
    VStack(spacing: 12) {
        Notice(title: "Pro ended · AI and execution paused", message: "Your lists, results and sources stay available.") {
            Button("Restart Pro") {}
        }
        Notice(title: "You're offline")
    }
    .padding()
    .frame(width: 520)
    .background(TFColor.bgSurface)
}
