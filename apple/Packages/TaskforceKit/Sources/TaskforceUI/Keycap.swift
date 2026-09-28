import SwiftUI

/// Keycap (Figma 3:379): 단축키 표시. return 같은 키는 SF Symbol로 그린다.
public struct Keycap: View {
    enum Content {
        case text(String)
        case symbol(String)
    }

    let content: Content

    /// "⌘K"
    public init(_ text: String) {
        content = .text(text)
    }

    /// SF Symbol 이름 (예: "return")
    public init(systemImage: String) {
        content = .symbol(systemImage)
    }

    public var body: some View {
        Group {
            switch content {
            case .text(let text): Text(text)
            case .symbol(let name): Image(systemName: name)
            }
        }
        .font(TFFont.caption)
        .foregroundStyle(TFColor.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, TFSpace.xs)
        .frame(minWidth: 20, minHeight: 20)
        .background(TFColor.fillKeycap, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
    }
}

#Preview("Keycap") {
    HStack(spacing: 8) {
        Keycap("⌘K")
        Keycap(systemImage: "return")
        Keycap("esc")
        Keycap("⌥Space")
    }
    .padding()
}
