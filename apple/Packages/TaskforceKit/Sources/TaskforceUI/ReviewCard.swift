import SwiftUI
import TaskforceKit

/// 캡슐 버튼 (Review card의 Confirm · Dismiss, 빈 화면의 Connect). 최소 44, 글자와 함께 커진다 (C3). 그림자 없음.
public struct CapsuleButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// fill/inverse 바탕 + text/inverse
        case primary
        /// fill/secondary 바탕 + text/primary
        case secondary
    }

    let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TFFont.headline)
            .foregroundStyle(kind == .primary ? TFColor.textInverse : TFColor.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 10)
            .padding(.horizontal, TFSpace.lg)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(kind == .primary ? TFColor.fillInverse : TFColor.fillSecondary, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Review card (Figma 5:6, iPhone): 제목 + 확인할 값 + 근거 1줄 + Confirm / Dismiss.
/// 설명 문장 · 이유 캡션은 두지 않는다 (C1). 한 번에 한 장만 (S1).
public struct ReviewCard<Evidence: View>: View {
    let title: String
    let value: String?
    let busy: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let evidence: Evidence

    public init(
        title: String,
        value: String?,
        busy: Bool = false,
        onConfirm: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        @ViewBuilder evidence: () -> Evidence
    ) {
        self.title = title
        self.value = value
        self.busy = busy
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.evidence = evidence()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.md) {
            HStack(alignment: .firstTextBaseline, spacing: TFSpace.md) {
                Text(title)
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let value {
                    Text(value)
                        .font(TFFont.callout)
                        .foregroundStyle(TFColor.textSecondary)
                        .fixedSize()
                }
            }
            evidence
            HStack(spacing: TFSpace.sm) {
                Button("Confirm", action: onConfirm)
                    .buttonStyle(CapsuleButtonStyle(.primary))
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(CapsuleButtonStyle(.secondary))
            }
            .disabled(busy)
        }
        .padding(TFSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFColor.bgSurface, in: RoundedRectangle(cornerRadius: TFRadius.lg, style: .continuous))
    }
}

#Preview("Review card") {
    VStack(spacing: 24) {
        ReviewCard(title: "제안서 보내기", value: "Fri", onConfirm: {}, onDismiss: {}) {
            EvidenceView(service: .notion, quote: "금요일쯤 보내드릴 수 있을 것 같아요", when: "Sep 22", source: "김대표 미팅 회의록", quoteLineLimit: 3)
        }
        ReviewCard(title: "Loop in the legal team", value: "Thu", onConfirm: {}, onDismiss: {}) {
            EvidenceView(service: .notion, quote: "Can you bring your legal team into the draft review?", when: "Sep 23", source: "Weekly sync", quoteLineLimit: 3)
        }
    }
    .padding()
}
