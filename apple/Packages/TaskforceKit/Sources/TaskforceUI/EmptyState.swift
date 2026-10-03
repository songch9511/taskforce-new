import SwiftUI

/// 빈 화면 (Figma M14 · M20 · M21): 가운데 기호 + 제목 + 설명. 동작은 액션 바에 둔다. VoiceOver는 한 요소로 읽는다.
/// 기호는 없어도 된다 (M21 `No tasks yet`).
public struct EmptyState: View {
    let systemImage: String?
    let title: String
    let message: String?

    public init(systemImage: String?, title: String, message: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: TFSpace.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(width: 27, height: 27)
            }
            Text(title)
                .font(TFFont.calloutEmphasis)
                .foregroundStyle(TFColor.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(TFFont.footnote)
                    .foregroundStyle(TFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .padding(.horizontal, TFSpace.xl)
        .padding(.bottom, TFSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Empty state") {
    EmptyState(systemImage: "wifi.slash", title: "Nothing saved on this Mac yet", message: "Tasks appear after Taskforce connects once.")
        .frame(width: 750, height: 372)
        .background(TFColor.bgElevated)
}
