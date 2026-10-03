import SwiftUI

/// 스크롤 영역 아래쪽 흐림 (Figma `Bottom fade`, 28): 영역 바탕색을 아래로 갈수록 진하게 덮는다.
/// 바탕색 토큰을 그대로 쓰므로 Dark에서도 맞는다. 넘치지 않는 화면에서는 끈다(`isActive`).
public struct ScrollEdgeFade: ViewModifier {
    let color: Color
    let height: CGFloat
    let isActive: Bool

    public init(color: Color, height: CGFloat = 28, isActive: Bool = true) {
        self.color = color
        self.height = height
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isActive {
                color
                    .frame(height: height)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// `ScrollEdgeFade`
    public func scrollEdgeFade(_ color: Color, height: CGFloat = 28, isActive: Bool = true) -> some View {
        modifier(ScrollEdgeFade(color: color, height: height, isActive: isActive))
    }
}

#Preview("Scroll edge fade") {
    ScrollView {
        VStack(spacing: 0) {
            ForEach(0..<12) { index in
                MacListRow(title: "할 일 \(index + 1)", accessory: "Fri")
            }
        }
        .padding(8)
    }
    .frame(width: 300, height: 240)
    .background(TFColor.settingsSidebar)
    .scrollEdgeFade(TFColor.settingsSidebar)
}
