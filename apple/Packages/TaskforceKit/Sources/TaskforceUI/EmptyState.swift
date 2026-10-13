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

/// 디자인 EmptyState README의 다섯 화면 (글자 그대로)
public enum PanelEmptyKind: CaseIterable, Sendable {
    /// 할 일이 하나도 없다 (이번 실행에서 받은 목록이 비었을 때만): Add task · Connect a source
    case noWork
    /// Review에 기다리는 결정이 없다 (쓰는 곳은 S4 Review)
    case noDecisions
    /// 목록 없이 오프라인: Try again
    case offline
    /// 목록을 읽지 못함: Try again
    case couldNotLoad
    /// 검색 · 필터에 맞는 일이 없다: Clear filters
    case noMatch

    public var title: String {
        switch self {
        case .noWork: "Nothing on your plate yet."
        case .noDecisions: "No decisions waiting"
        case .offline: "You're offline"
        case .couldNotLoad: "Couldn't load your work"
        case .noMatch: "No matching work"
        }
    }
}

/// EmptyState (0.2.0 디자인 시스템 Molecules): 무엇이 없는지 말하는 제목 + 다음 걸음 버튼. 설명 문단은 없다.
/// 쓰는 곳: All work(WorkList) · Review · Chats. 다섯 화면은 서로 다른 제목을 쓴다(`PanelEmptyKind`, 디자인 D-14).
/// "All caught up"이나 맨 "Nothing here"는 쓰지 않는다. 제목은 사실("No matching work"), 버튼은 빠져나가는 길("Clear filters").
public struct PanelEmptyState<Actions: View>: View {
    let title: String
    let actions: Actions

    public init(_ kind: PanelEmptyKind, @ViewBuilder actions: () -> Actions) {
        self.init(title: kind.title, actions: actions)
    }

    /// 다섯 화면 밖의 빈 화면 (예: Chats의 "No conversations yet.")
    public init(title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(TFFont.calloutEmphasis)
                .foregroundStyle(TFColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if Actions.self != EmptyView.self {
                HStack(spacing: TFSpace.sm) { actions }
                    .padding(.top, TFSpace.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, TFSpace.md)
        .accessibilityElement(children: .contain)
    }
}

extension PanelEmptyState where Actions == EmptyView {
    public init(_ kind: PanelEmptyKind) {
        self.init(kind, actions: { EmptyView() })
    }

    public init(title: String) {
        self.init(title: title, actions: { EmptyView() })
    }
}

#Preview("Panel empty states") {
    VStack(spacing: 0) {
        PanelEmptyState(.noWork) {
            Button("Add task") {}.buttonStyle(TFButtonStyle(.primary, size: .md))
            Button("Connect a source") {}.buttonStyle(TFButtonStyle(.secondary, size: .md))
        }
        PanelEmptyState(.noDecisions) { Button("All work") {}.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
        PanelEmptyState(.offline) { Button("Try again") {}.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
        PanelEmptyState(.couldNotLoad) { Button("Try again") {}.buttonStyle(TFButtonStyle(.secondary, size: .md)) }
        PanelEmptyState(.noMatch) { Button("Clear filters") {}.buttonStyle(TFButtonStyle(.text, size: .md)) }
    }
    .frame(width: 348)
    .background(TFColor.bgPanel)
}

#Preview("Empty state") {
    EmptyState(systemImage: "wifi.slash", title: "Nothing saved on this Mac yet", message: "Tasks appear after Taskforce connects once.")
        .frame(width: 750, height: 372)
        .background(TFColor.bgElevated)
}
