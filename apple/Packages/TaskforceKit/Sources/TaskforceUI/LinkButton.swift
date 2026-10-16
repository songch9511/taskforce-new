import SwiftUI

/// Button `link` (0.2.0 디자인 시스템 Atoms, DS `.tf-btn.is-link`): 줄 안에서 쓰는 글자 링크. `text/accent` 색이고 **글꼴은 주변 줄을 따른다** (정하지 않는다),
/// 호버 때 밑줄. 누르는 영역은 글자보다 가로 2씩 넓다 (안쪽 0/2 · 바깥 −2: 줄의 폭은 그대로).
/// 쓰는 곳: Send again · View full · 후보 고르기 (전달 줄 · 잘린 답). 장식 없이 동작 하나만 있다
public struct LinkButton: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(LinkButtonStyle())
    }
}

/// `LinkButton`의 모양: 글꼴을 정하지 않는다 (둘러싼 `.font(…)`가 이긴다). 눌리면 .98로 줄고, 꺼지면 흐려진다
public struct LinkButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        LinkButtonBody(configuration: configuration)
    }
}

private struct LinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(TFColor.textAccent)
            .underline(hovering && isEnabled, pattern: .solid)
            .padding(.horizontal, TFSpace.xxs)
            .contentShape(RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            .padding(.horizontal, -TFSpace.xxs)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? TFMotion.pressScale : 1)
            .onHover { hovering = $0 }
            .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
    }
}

#Preview("Link button") {
    HStack(spacing: 8) {
        Text("Not sent · Access not verified").foregroundStyle(TFColor.textSecondary)
        LinkButton("Send again") {}
    }
    .environment(\.font, TFFont.footnote)
    .padding(16)
    .background(TFColor.bgPanel)
}
