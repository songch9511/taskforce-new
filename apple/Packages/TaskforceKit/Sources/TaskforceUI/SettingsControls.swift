import SwiftUI

// 0.2.0 설정 창의 컨트롤 원자 (디자인 SSOT Atoms: Toggle · Button size sm · TextField size sm). 설정 컨트롤은 24pt(`size="sm"`).
// 패널(EdgePanel) 쪽 크기는 쓰는 화면이 생길 때 더한다.

/// Toggle (0.2.0 Atoms): 켜면 잉크(`fill/inverse`) 트랙, 끄면 3:1 경계를 지키는 `status/step-inactive` 트랙. 34×20, 손잡이 16.
/// 바로 적용된다. 확인이 필요하거나 돈이 드는 변경은 버튼을 쓴다. 옆에 "On" 같은 상태 글자를 쓰지 않는다.
/// 이름은 행의 라벨이 준다: `Toggle(label, isOn:).labelsHidden().toggleStyle(.tf)` (접근성은 시스템 스위치와 같다)
public struct TFToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        TFSwitch(configuration: configuration)
    }
}

extension ToggleStyle where Self == TFToggleStyle {
    public static var tf: TFToggleStyle { TFToggleStyle() }
}

private struct TFSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let on = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(on ? TFColor.fillInverse : TFColor.statusStepInactive)
                .frame(width: SettingsTray.toggleSize.width, height: SettingsTray.toggleSize.height)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(on ? TFColor.textInverse : Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .offset(x: on ? 16 : 2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(TFMotion.ease(0.18), value: on)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Button (0.2.0 Atoms). `primary` = 잉크 면(화면의 주 동작 하나), `secondary` = `bg/field` 면, `text` = 면 없는 글자 버튼(호버 때 `bg/selected`).
/// - sm: 24pt, 12. 설정 행 · Notice · 필터 요약의 Clear
/// - md: 32pt, 13. 패널의 빈 화면 (Add task · Try again · Clear filters)
/// primary · secondary는 캡슐 semibold, text는 모서리 5 · medium. 누르면 .98로 줄고, 꺼지면 글자는 그대로 두고 흐려진다.
public struct TFButtonStyle: ButtonStyle {
    public enum Kind: Sendable, Hashable {
        case primary, secondary, text
    }

    public enum Size: Sendable, Hashable {
        case sm, md

        /// 버튼 높이 (디자인 `.tf-btn` 32 · `.is-sm` 24 · `.is-text` 28)
        public func height(_ kind: Kind) -> CGFloat {
            switch (self, kind) {
            case (.sm, _): SettingsTray.controlHeight
            case (.md, .text): 28
            case (.md, _): 32
            }
        }
    }

    let kind: Kind
    let size: Size

    public init(_ kind: Kind = .secondary, size: Size = .sm) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        TFButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct TFButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TFButtonStyle.Kind
    let size: TFButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = kind == .text
            ? AnyShape(RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
            : AnyShape(Capsule())
        configuration.label
            .font(.system(size: size == .sm ? 12 : 13, weight: kind == .text ? .medium : .semibold))
            .foregroundStyle(kind == .primary ? TFColor.textInverse : TFColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: size.height(kind))
            .background(background, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? TFMotion.pressScale : 1)
            .onHover { hovering = $0 }
            .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
    }

    private var horizontalPadding: CGFloat {
        switch (kind, size) {
        case (.text, _): TFSpace.sm
        case (_, .sm): 11
        case (_, .md): 14
        }
    }

    private var background: Color {
        switch kind {
        case .primary: TFColor.fillInverse
        case .secondary: hovering && isEnabled ? TFColor.bgSelected : TFColor.bgField
        case .text: hovering && isEnabled ? TFColor.bgSelected : .clear
        }
    }
}

/// TextField size sm (0.2.0 Atoms): 설정 행 끝의 편집 글자. 24pt · 폭 180, `bg/field` 면에 `border/default` 1pt 가장자리,
/// 포커스면 1.5pt `border/accent` 안쪽 링. 커서는 시스템 accent(앱 accent = text/accent).
/// 포커스는 쓰는 쪽의 `@FocusState`가 정하고 그 값을 넘긴다 (포커스 바인딩을 둘 두지 않는다)
public struct SettingsFieldStyle: ViewModifier {
    let focused: Bool

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(TFFont.footnote)
            .foregroundStyle(TFColor.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, TFSpace.sm)
            .frame(width: SettingsTray.fieldWidth, height: SettingsTray.controlHeight)
            .background(TFColor.bgField, in: shape)
            .overlay(shape.strokeBorder(focused ? TFColor.borderAccent : TFColor.borderDefault, lineWidth: focused ? 1.5 : 1))
    }
}

extension View {
    /// 설정 행의 TextField size sm 모양. `focused`: 쓰는 쪽 `@FocusState`의 이 칸 값
    public func settingsField(focused: Bool = false) -> some View {
        modifier(SettingsFieldStyle(focused: focused))
    }
}

#Preview("Settings controls") {
    @Previewable @State var on = true
    @Previewable @State var name = "Alex Kim"
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Toggle("Use AI", isOn: $on).labelsHidden().toggleStyle(.tf)
            Toggle("Off", isOn: .constant(false)).labelsHidden().toggleStyle(.tf)
            Toggle("Disabled", isOn: .constant(true)).labelsHidden().toggleStyle(.tf).disabled(true)
        }
        HStack {
            Button("Reconnect") {}.buttonStyle(TFButtonStyle(.primary))
            Button("Sign Out") {}.buttonStyle(TFButtonStyle())
            Button("Sync Now") {}.buttonStyle(TFButtonStyle()).disabled(true)
        }
        TextField("Name", text: $name).settingsField()
    }
    .padding()
    .background(TFColor.bgElevated)
}
