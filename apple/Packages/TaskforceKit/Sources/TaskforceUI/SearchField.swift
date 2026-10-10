import SwiftUI

/// TextField md + 앞 아이콘 + 끝 컨트롤 (0.2.0 Atoms TextField `icon` · `trailing` · `hideLabel`): All work의 검색칸.
/// `bg/field` 면 하나(테두리 없음), 모서리 8, 32pt. 포커스면 1.5pt `border/accent` 안쪽 링, 대비 높이기면 1pt `border/control` 가장자리.
/// 라벨은 VoiceOver에만(`label`), 칸 안 자리 글은 `prompt`. 끝 컨트롤(28pt)은 칸 안 오른쪽 4pt (예: WorkList의 필터 IconButton).
public struct TFSearchField<Trailing: View>: View {
    let label: String
    let prompt: String
    @Binding var text: String
    let trailing: Trailing
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ label: String, prompt: String, text: Binding<String>, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.prompt = prompt
        _text = text
        self.trailing = trailing()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous)
        HStack(spacing: 0) {
            // 아이콘은 왼쪽 9, 글자는 30에서 시작 (디자인 `.tf-control.has-lead`)
            TFIcon.search.image(size: 14)
                .foregroundStyle(TFColor.textSecondarySelected)
                .padding(.leading, 9)
                .padding(.trailing, 7)
            TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(TFColor.textSecondarySelected))
                .textFieldStyle(.plain)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
                .focused($focused)
                .labelsHidden()
                .accessibilityLabel(label)
            trailing
                .padding(.leading, TFSpace.sm)
                .padding(.trailing, TFSpace.xs)
        }
        .frame(minHeight: 32)
        .background(TFColor.bgField, in: shape)
        .overlay {
            if focused {
                shape.strokeBorder(TFColor.borderAccent, lineWidth: 1.5)
            } else if contrast == .increased {
                shape.strokeBorder(TFColor.borderControl, lineWidth: 1)
            }
        }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: focused)
    }
}

extension TFSearchField where Trailing == EmptyView {
    public init(_ label: String, prompt: String, text: Binding<String>) {
        self.init(label, prompt: prompt, text: text, trailing: { EmptyView() })
    }
}

#Preview("Search field") {
    @Previewable @State var text = ""
    TFSearchField("Search work", prompt: "Search work…", text: $text) {
        TFIconButton(.filters, label: "Filters", action: {})
    }
    .padding()
    .frame(width: 380)
    .background(TFColor.bgPanel)
}
