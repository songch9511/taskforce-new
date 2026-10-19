#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit

/// Save를 눌렀을 때 칸의 값을 읽는 길 (Return과 같은 길). 화면이 하나 만들어 칸과 버튼에 같이 넘긴다
@MainActor
public final class SecureFieldSmHandle {
    let inner = SecretFieldHandle()

    public init() {}

    /// 칸의 값을 `SecretBox`로 한 번 읽어 칸의 `onSubmit`으로 보내고 칸을 비운다. 빈 칸이면 아무것도 보내지 않는다
    public func submit() {
        inner.submit()
    }
}

/// SecureFieldSm (0.2.0 Atoms, DS `TextField size="sm" type="password"`): 설정 행 끝의 비밀 한 줄 칸 (OpenRouter 키).
/// 24pt · 폭 180, `bg/field` 면에 1pt 가장자리, 포커스면 1.5pt `border/accent`. 글자는 점으로 가려진다.
/// - 칸은 AppKit `NSSecureTextField`다: 값은 칸에서 **한 번** 읽고 곧바로 칸을 비운다 (Return · `SecureFieldSmHandle.submit()`).
///   실행 취소 기록 · 접근성 값(마스크) · UserDefaults · Keychain · 로그에 남기지 않는다.
/// - 값은 `SecretBox`로만 나간다 (글로 찍어도 값이 나오지 않는다). 이 부품은 값을 저장하지 않는다.
/// - `label`은 화면 읽기 이름이다 (칸 위에 보이지 않는다, DS `hideLabel`). `placeholder`는 비었을 때의 자리 글.
public struct SecureFieldSm: View {
    let label: String
    let placeholder: String?
    let handle: SecureFieldSmHandle
    let clearToken: Int
    let onSubmit: (SecretBox) -> Void
    @State private var focused = false

    public init(label: String, placeholder: String? = nil, handle: SecureFieldSmHandle, clearToken: Int = 0, onSubmit: @escaping (SecretBox) -> Void) {
        self.label = label
        self.placeholder = placeholder
        self.handle = handle
        self.clearToken = clearToken
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous)
        SecretField(
            label: label, placeholder: placeholder, fontSize: 13, focusRequest: 0, clearToken: clearToken, handle: handle.inner,
            onFocusChange: { focused = $0 }, onHasText: { _ in }, onSubmit: onSubmit
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, TFSpace.sm)
        .frame(width: SettingsTray.fieldWidth, height: SettingsTray.controlHeight)
        .background(TFColor.bgField, in: shape)
        .overlay(shape.strokeBorder(focused ? TFColor.borderAccent : TFColor.borderDefault, lineWidth: focused ? 1.5 : 1))
        .accessibilityElement(children: .contain)
    }
}
#endif
