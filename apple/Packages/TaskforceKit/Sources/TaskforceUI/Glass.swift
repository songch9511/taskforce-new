import SwiftUI

// Liquid Glass (iOS 26 · macOS 26): 내용 위에 떠 있는 면과 컨트롤에만 쓴다. 할 일 행 · Review card 같은 내용은 평평하게 둔다 (Figma 156:6 P1).
// 최소 OS(iOS 18 · macOS 15)에서는 material을 쓴다.

/// 떠 있는 캡슐 면 (iPhone 삭제 뒤 "Deleted  Undo" 막대): iOS 26 · macOS 26은 regular 유리, 그 전은 regular material. 그림자 없음.
public struct TFGlassCapsule: ViewModifier {
    public init() {}

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

extension View {
    /// `TFGlassCapsule`
    public func tfGlassCapsule() -> some View {
        modifier(TFGlassCapsule())
    }
}
