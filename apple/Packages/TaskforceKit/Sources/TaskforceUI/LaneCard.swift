import SwiftUI

/// 상세의 갈래 (Figma M1 Lane · Taskforce 181:1642, iPhone P2 `Section · Taskforce` 246:1627): 굵은 갈래 제목 + 카드 한 장.
/// 카드는 bg/elevated · settings/line 테두리, 제목(상태 문장) · 부제(선택) · 버튼 하나(선택, 예 `View Draft`).
/// - Mac: 제목 13 semibold, 카드 r12 · 안쪽 10 / 14 · 12, 버튼은 오른쪽 `QuietButton(.small)`
/// - iPhone: 제목 15 semibold, 카드 r16 · 안쪽 12 / 16 · 12 / 8, 버튼은 문장 아래 `QuietButton(.iOS)`(누르는 영역 44)
/// 긴 상태 문장은 자르지 않는다 (Dynamic Type에서 함께 커진다).
public struct LaneCard: View {
    public struct Action {
        let title: String
        let perform: () -> Void

        public init(_ title: String, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    let heading: String
    let title: String
    let subtitle: String?
    let action: Action?

    public init(heading: String, title: String, subtitle: String? = nil, action: Action? = nil) {
        self.heading = heading
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            // VoiceOver는 카드 문장에서 "Taskforce, <상태>"로 한 번만 읽는다
            Text(heading)
                .font(Metrics.headingFont)
                .foregroundStyle(TFColor.textPrimary)
                .accessibilityHidden(true)
            card
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
        return Group {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 6) {
                sentence
                if let action {
                    QuietButton(action.title, size: .iOS, action: action.perform)
                }
            }
            .padding(EdgeInsets(top: TFSpace.md, leading: TFSpace.lg, bottom: action == nil ? TFSpace.md : TFSpace.sm, trailing: TFSpace.md))
            #else
            HStack(spacing: TFSpace.md) {
                sentence
                if let action {
                    QuietButton(action.title, size: .small, action: action.perform)
                        .fixedSize()
                }
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: TFSpace.md))
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgElevated, in: shape)
        .overlay(shape.strokeBorder(TFColor.settingsLine, lineWidth: 1))
    }

    /// 상태 문장 + 부제. VoiceOver는 "Taskforce, <상태>, <부제>" 한 요소로, 버튼은 따로 읽는다
    private var sentence: some View {
        VStack(alignment: .leading, spacing: TFSpace.xxs) {
            Text(title)
                .font(Metrics.titleFont)
                .foregroundStyle(TFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(Metrics.subtitleFont)
                    .foregroundStyle(TFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(heading: heading, title: title, subtitle: subtitle))
    }

    /// "Taskforce, Draft ready[, AI draft · 14:20]"
    nonisolated static func accessibilityLabel(heading: String, title: String, subtitle: String?) -> String {
        ([heading, title] + [subtitle].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: ", ")
    }

    private enum Metrics {
        #if os(iOS)
        static let headingFont = TFFont.calloutEmphasis
        static let titleFont = TFFont.body
        static let subtitleFont = TFFont.callout
        static let radius: CGFloat = 16
        #else
        static let headingFont = TFFont.footnoteEmphasis
        static let titleFont = TFFont.footnote
        static let subtitleFont = TFFont.meta
        static let radius = TFRadius.panel
        #endif
    }
}

#Preview("Lane · Taskforce") {
    VStack(alignment: .leading, spacing: 18) {
        LaneCard(heading: "Taskforce", title: "회의록 3건으로 질문지 초안 작성 중", subtitle: "AI draft, not the spec", action: .init("View Draft") {})
        LaneCard(heading: "Taskforce", title: "Writing draft", subtitle: "Started 14:02")
        LaneCard(
            heading: "Taskforce", title: "Stopped. No new steps will start.", subtitle: "Finishing the current step.",
            action: .init("View Draft") {}
        )
    }
    .padding(24)
    .frame(width: 449)
    .background(TFColor.bgElevated)
}
