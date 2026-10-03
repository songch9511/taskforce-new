import SwiftUI
import TaskforceKit

/// 캡슐 버튼 (Figma Button 159:34: Review card의 Confirm · Dismiss, 빈 화면의 Connect, 동의 화면). 최소 44, 글자와 함께 커진다 (C3). 그림자 없음.
/// 꺼지면 0.35 (Figma P10 오프라인).
public struct CapsuleButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// fill/inverse 바탕 + text/inverse (화면에 하나)
        case primary
        /// settings/fill 바탕 + text/primary (Figma `Button · Dismiss`)
        case secondary
    }

    let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, kind: kind)
    }
}

private struct CapsuleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: CapsuleButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(TFFont.headline)
            .foregroundStyle(kind == .primary ? TFColor.textInverse : TFColor.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 10)
            .padding(.horizontal, TFSpace.lg)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(kind == .primary ? TFColor.fillInverse : TFColor.settingsFill, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}

/// Review card (Figma 156:6 P1 190:3790 · P10 292:2746, iPhone): 확인 이유 + `1 of 4` → 제목 → 확인할 값 → 원문 → Confirm / Dismiss.
/// 확인 이유는 짧은 표기 하나뿐이다(`ConfirmReasonText`, 2026-09-30). 설명 문장은 두지 않는다 (C1). 목록에는 한 번에 한 장 (S1).
/// 면은 bg/elevated + settings/line 테두리 (r16). `canAct`가 거짓이면(오프라인 · 저장본) 두 버튼을 끄고 `note`를 아래에 둔다 (P10).
public struct ReviewCard<Evidence: View>: View {
    let title: String
    let value: String?
    let reason: String?
    let position: String?
    let changed: Bool
    let busy: Bool
    let canAct: Bool
    let note: String?
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let evidence: Evidence

    @Environment(\.dynamicTypeSize) private var typeSize

    /// `reason`: 확인 이유 (`ConfirmReasonText.label`). `value`: 확인할 기한 (`Due Fri`). `position`: `1 of 4` (`PhoneHome.reviewPosition`).
    /// `changed`: 마지막으로 본 뒤 바뀜 (6pt Ink 점)
    public init(
        title: String,
        value: String?,
        reason: String? = nil,
        position: String? = nil,
        changed: Bool = false,
        busy: Bool = false,
        canAct: Bool = true,
        note: String? = nil,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder evidence: () -> Evidence
    ) {
        self.title = title
        self.value = value
        self.reason = reason
        self.position = position
        self.changed = changed
        self.busy = busy
        self.canAct = canAct
        self.note = note
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.evidence = evidence()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: TFSpace.md) {
            if reason != nil || position != nil || changed {
                header
            }
            Text(title)
                .font(TFFont.title)
                .foregroundStyle(TFColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let value {
                // Figma `Owner  You, as PM  proposed`의 자리: 이름 + 값
                HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) {
                    Text("Due")
                        .font(TFFont.callout)
                        .foregroundStyle(TFColor.textSecondary)
                    Text(value)
                        .font(TFFont.headline)
                        .foregroundStyle(TFColor.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
            evidence
            // 큰 글자(접근성 크기)에서는 위아래로 (나란히 두면 단어가 잘린다)
            let buttons = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            buttons {
                Button("Confirm", action: onConfirm)
                    .buttonStyle(CapsuleButtonStyle(.primary))
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(CapsuleButtonStyle(.secondary))
            }
            .disabled(busy || !canAct)
            if let note {
                Text(note)
                    .font(TFFont.callout)
                    .foregroundStyle(TFColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(TFSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgElevated, in: shape)
        .overlay(shape.strokeBorder(TFColor.settingsLine, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: TFSpace.sm) {
            Text(reason ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if changed {
                Circle()
                    .fill(TFColor.textPrimary)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            }
            if let position {
                Text(position)
                    .fixedSize()
            }
        }
        .font(TFFont.callout)
        .foregroundStyle(TFColor.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([reason, changed ? "Changed" : nil, position].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview("Review card") {
    VStack(spacing: 24) {
        ReviewCard(title: "새 온보딩 QA (결제·환불 시나리오와 접근성 점검 포함)", value: "Fri", reason: "Not sure it's yours", position: "1 of 4", onConfirm: {}, onDismiss: {}) {
            EvidenceView(service: .notion, quote: "금요일쯤 보내드릴 수 있을 것 같아요", when: "Sep 22", source: "김대표 미팅 회의록", quoteLineLimit: 3)
        }
        ReviewCard(
            title: "Loop in the legal team", value: "Thu", reason: "Due date unclear", position: "2 of 4", changed: true, canAct: false,
            note: "Confirm and Dismiss wait for a connection. Nothing is saved for later.", onConfirm: {}, onDismiss: {}
        ) {
            EmptyView()
        }
    }
    .padding()
}
