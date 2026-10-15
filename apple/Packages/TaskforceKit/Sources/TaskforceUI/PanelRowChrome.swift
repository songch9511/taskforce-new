import SwiftUI
import TaskforceKit

/// 그룹 라벨 (0.2.0 디자인 시스템 GroupLabel, OA U2): `caption` 12/16 600 `text/secondary`, 위 18 · 아래 4 · 가로 8. **개수 없음**. 오른쪽에 링크 하나("Show all")가 올 수 있다
public struct GroupLabel<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: TFSpace.sm) {
            Text(title)
                .font(TFFont.caption)
                .foregroundStyle(TFColor.textSecondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(EdgeInsets(top: 18, leading: TFSpace.sm, bottom: TFSpace.xs, trailing: TFSpace.sm))
    }
}

extension GroupLabel where Trailing == EmptyView {
    public init(_ title: String) {
        self.init(title, trailing: { EmptyView() })
    }
}

/// 줄 끝 링크 (DS `.tf-link`): `footnote`, `text/secondary` → 호버 `text/primary` + `bg/selected`, 모서리 5. 같은 줄 안의 동사("Show all")에만 쓴다. 주 동작이 아니다
public struct QuietLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(TFFont.footnote)
                .foregroundStyle(hovering ? TFColor.textPrimary : TFColor.textSecondary)
                .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                .background(hovering ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: hovering)
        // 라벨 줄 안에서 글자가 라벨과 같은 높이에 앉게
        .padding(.vertical, -4)
    }
}

/// Ask 알약 (DS README Context chips, Figma `28:1396`): 행에 호버 · 키보드 포커스가 있을 때 행 오른쪽에 뜨는 `bg/elevated` 알약 (43 × 24).
/// 누르면 앞 Assistant 창에 그 항목의 칩을 더한다. 접근성 이름은 "Ask about #139"(U1-12 꼴)
public struct AskPill: View {
    nonisolated public static let height: CGFloat = 24
    nonisolated public static let title = "Ask"

    let label: String
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    /// - label: 접근성 이름 ("Ask about #139" · "Ask about Shape launch")
    public init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    /// "Ask about #139" (번호가 있으면 번호, 없으면 이름)
    nonisolated public static func accessibilityName(number: Int?, name: String) -> String {
        "Ask about \(IssueNumberStore.label(number) ?? name)"
    }

    public var body: some View {
        Button(action: action) {
            Text(Self.title)
                .font(TFFont.footnote)
                .foregroundStyle(TFColor.textPrimary)
                .padding(.horizontal, TFSpace.md)
                .frame(height: Self.height)
                .background(TFColor.bgElevated, in: Capsule())
                .overlay { if contrast == .increased { Capsule().strokeBorder(TFColor.borderControl, lineWidth: 1) } }
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 목록 행의 바탕 (ProjectRow · IssueRow · SessionRow가 함께 쓴다): 안쪽 가로 10 · 세로 8, 모서리 8, 지금 행 · 호버 · 레일에서 가리킨 행은 `bg/selected`.
/// 호버 · 키보드 포커스에서 Ask 알약이 오른쪽에 뜨고 그동안 오른쪽 meta를 가린다 (meta를 줄이지 않는다). 알약은 행과 따로 누르는 영역이다
struct PanelRowChrome<Content: View>: View {
    let current: Bool
    let highlighted: Bool
    let accessibilityName: String
    let askLabel: String?
    let onOpen: () -> Void
    let onAsk: (() -> Void)?
    let content: (_ lit: Bool, _ asking: Bool) -> Content

    @State private var hovering = false
    @FocusState private var focused: Bool

    init(
        current: Bool, highlighted: Bool, accessibilityName: String, askLabel: String?, onOpen: @escaping () -> Void, onAsk: (() -> Void)?,
        @ViewBuilder content: @escaping (_ lit: Bool, _ asking: Bool) -> Content
    ) {
        self.current = current
        self.highlighted = highlighted
        self.accessibilityName = accessibilityName
        self.askLabel = askLabel
        self.onOpen = onOpen
        self.onAsk = onAsk
        self.content = content
    }

    /// 스냅샷만 (Release는 늘 거짓): 호버한 것으로 그린다
    private var pretendsHover: Bool {
        #if DEBUG
        PanelRowSnapshot.askingNames.contains(accessibilityName)
        #else
        false
        #endif
    }

    private var lit: Bool { hovering || pretendsHover || current || highlighted }
    private var asking: Bool { onAsk != nil && (hovering || pretendsHover || focused) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                content(lit, asking)
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(lit ? TFColor.bgSelected : Color.clear, in: RoundedRectangle(cornerRadius: TFRadius.md, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityLabel(accessibilityName)
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityActions {
                if let askLabel, let onAsk { Button(askLabel, action: onAsk) }
            }
            if asking, let askLabel, let onAsk {
                AskPill(label: askLabel, action: onAsk)
                    .padding(.trailing, 10)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(TFMotion.ease(TFMotion.hoverFade), value: lit)
        .animation(TFMotion.ease(TFMotion.hoverFade), value: asking)
    }
}

#if DEBUG
/// 디자인 비교 스냅샷만 (Debug): 이 접근성 이름의 행에 Ask 알약을 호버한 것처럼 보인다. 앱의 다른 곳에서는 쓰지 않는다
public enum PanelRowSnapshot {
    nonisolated(unsafe) public static var askingNames: Set<String> = []
}
#endif
