import SwiftUI

// Liquid Glass (iOS 26 · macOS 26): 내용 위에 떠 있는 면과 컨트롤에만 쓴다. 할 일 행 같은 내용은 평평하게 둔다.
// 최소 OS(iOS 18 · macOS 15)에서는 지금 모양(토큰 바탕 · 캡슐 버튼)을 그대로 쓴다.

/// 떠 있는 카드 면 (iPhone Review card): iOS 26 · macOS 26은 regular 유리, 그 전은 bg/surface 바탕. 그림자 없음.
public struct TFGlassCard: ViewModifier {
    let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = TFRadius.lg) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(TFColor.bgSurface, in: shape)
        }
    }
}

extension View {
    /// `TFGlassCard`
    public func tfGlassCard(cornerRadius: CGFloat = TFRadius.lg) -> some View {
        modifier(TFGlassCard(cornerRadius: cornerRadius))
    }
}

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

/// 유리 캡슐 버튼 (Review card의 Confirm · Dismiss). 폭을 채우고 글자와 함께 커진다.
/// - primary: 잉크(fill/inverse)로 물든 `.glassProminent` + text/inverse. accent는 쓰지 않는다
/// - secondary: `.glass` + text/primary
///
/// iOS 26 · macOS 26 전에는 `CapsuleButtonStyle`과 같다.
public struct TFGlassButtonStyle: PrimitiveButtonStyle {
    let kind: CapsuleButtonStyle.Kind

    public init(_ kind: CapsuleButtonStyle.Kind) {
        self.kind = kind
    }

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            let label = configuration.label
                .font(TFFont.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            switch kind {
            case .primary:
                Button(action: configuration.trigger) { label.foregroundStyle(TFColor.textInverse) }
                    .buttonStyle(.glassProminent)
                    .tint(TFColor.fillInverse)
                    .controlSize(.large)
            case .secondary:
                Button(action: configuration.trigger) { label.foregroundStyle(TFColor.textPrimary) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        } else {
            Button(action: configuration.trigger) { configuration.label }
                .buttonStyle(CapsuleButtonStyle(kind))
        }
    }
}

/// 나란한 유리 컨트롤 묶음: iOS 26 · macOS 26은 `GlassEffectContainer`로 한 번에 그린다. 그 전은 그대로.
/// `spacing`보다 가까운 유리끼리는 이어져 보인다 (0이면 잇지 않는다).
public struct TFGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(spacing: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

#Preview("Glass card · buttons") {
    ZStack {
        // 유리가 보이도록 뒤에 글자 목록
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<14) { index in
                Text("Task row \(index) behind the glass").font(TFFont.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(TFColor.bgCanvas)

        VStack(alignment: .leading, spacing: TFSpace.md) {
            Text("법무팀에 계약서 초안 전달")
                .font(TFFont.headline)
                .foregroundStyle(TFColor.textPrimary)
            TFGlassGroup {
                HStack(spacing: TFSpace.sm) {
                    Button("Confirm") {}
                        .buttonStyle(TFGlassButtonStyle(.primary))
                    Button("Dismiss") {}
                        .buttonStyle(TFGlassButtonStyle(.secondary))
                }
            }
        }
        .padding(TFSpace.lg)
        .tfGlassCard()
        .padding()
    }
}
