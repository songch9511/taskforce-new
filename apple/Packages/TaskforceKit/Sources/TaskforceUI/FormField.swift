import SwiftUI

/// 폼 한 줄 (Figma M8 `Field · …` 185:2555): 왼쪽 라벨 칸 78(12 semibold text/secondary) + 사이 12 + 오른쪽 컨트롤.
/// 라벨은 컨트롤 첫 줄과 글자 기준선을 맞춘다 (입력칸이면 Figma의 5 내림과 같은 자리).
/// VoiceOver: 컨트롤이 글이면 "라벨, 값" 한 요소, 입력칸이면(`isInput`) 라벨이 입력칸 이름이 된다 (`GrowingTextField`에 같은 라벨을 준다).
public struct FormField<Content: View>: View {
    let label: String
    let isInput: Bool
    let content: Content

    public init(_ label: String, isInput: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.isInput = isInput
        self.content = content()
    }

    nonisolated public static var labelWidth: CGFloat { 78 }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TFSpace.md) {
            Text(label)
                .font(TFFont.caption)
                .foregroundStyle(TFColor.textSecondary)
                .frame(width: Self.labelWidth, alignment: .leading)
                .accessibilityHidden(isInput)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: isInput ? .contain : .combine)
    }
}

/// 폼 값 글자 (Figma M8 Output · Limit: 값 13 + 설명 12 text/secondary)
public struct FormValue: View {
    let value: String
    let detail: String?

    public init(_ value: String, detail: String? = nil) {
        self.value = value
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.xxs) {
            Text(value)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
            if let detail {
                Text(detail)
                    .font(TFFont.meta)
                    .foregroundStyle(TFColor.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 여러 줄 입력칸 (Figma M8 `Text field` 185:2559): bg/elevated r6, 안쪽 5 · 8, 글자 13.
/// 3줄까지 늘고 그 뒤로는 안에서 스크롤한다. 포커스면 fill/accent 테두리 + 3pt accent 35% 링 (Figma).
/// 포커스가 없을 때 테두리는 border/control: Figma의 border/default는 bg/elevated 위 1.3:1이라 입력칸 경계(비문자 3:1)에 못 미친다.
public struct GrowingTextField: View {
    let label: String
    let prompt: String?
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding

    /// 늘어나는 최대 줄 수
    nonisolated public static let maxLines = 3

    /// `label`: VoiceOver 이름 (보이는 라벨은 `FormField`), `prompt`: 비었을 때 자리 글
    public init(_ label: String, text: Binding<String>, prompt: String? = nil, isFocused: FocusState<Bool>.Binding) {
        self.label = label
        self.prompt = prompt
        _text = text
        self.isFocused = isFocused
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let focused = isFocused.wrappedValue
        TextField(label, text: $text, prompt: prompt.map { Text($0).foregroundStyle(TFColor.textSecondary) }, axis: .vertical)
            .textFieldStyle(.plain)
            .font(TFFont.footnote)
            .foregroundStyle(TFColor.textPrimary)
            .lineLimit(1...Self.maxLines)
            .focused(isFocused)
            .focusEffectDisabled()
            .padding(.vertical, 5)
            .padding(.horizontal, TFSpace.sm)
            .background(TFColor.bgElevated, in: shape)
            .overlay(shape.strokeBorder(focused ? TFColor.fillAccent : TFColor.borderControl, lineWidth: 1))
            .background(
                shape.inset(by: -3).fill(TFColor.fillAccent.opacity(focused ? 0.35 : 0))
            )
            .accessibilityLabel(label)
    }
}

#Preview("Form") {
    FormPreview()
}

private struct FormPreview: View {
    @State private var goal = "데모 때 나올 예상 질문 목록과 답변 초안. 결제 단계 이탈 관련 질문을 먼저 두고, 보안·개인정보 질문은 따로 묶기"
    @State private var empty = ""
    @FocusState private var goalFocused: Bool
    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.md) {
            FormField("Goal", isInput: true) {
                GrowingTextField("Goal", text: $goal, isFocused: $goalFocused)
            }
            FormField("Note", isInput: true) {
                GrowingTextField("Note", text: $empty, prompt: "What should the draft cover?", isFocused: $otherFocused)
            }
            FormField("Output") {
                FormValue("Draft in Taskforce", detail: "Nothing is sent or shared")
            }
            FormField("Cost") {
                FormValue("Uses credits")
            }
        }
        .padding(24)
        .frame(width: 449)
        .background(TFColor.bgElevated)
        .onAppear { goalFocused = true }
    }
}
