import SwiftUI
import TaskforceKit

/// 초안 본문 (Mac 런처 `‹ <할 일> › Draft` · iPhone 초안 화면, Figma 프레임 없음 — U2 Mac 계획 열린 질문 5).
/// 초안 제목 + 한 줄 설명(선택, 예 "AI draft · 14:20") + 고를 수 있는 본문. 보관 기간(90일)이 지나 본문을 지웠으면 본문 자리에 그 사실을 적는다.
/// 본문은 사용자 글이다: 화면에만 보이고 로그 · 디스크에 남기지 않는다.
public struct DraftBody: View {
    let artifact: Artifact
    let detail: String?

    public init(_ artifact: Artifact, detail: String? = nil) {
        self.artifact = artifact
        self.detail = detail
    }

    /// 본문을 지운 초안 (문구 후보)
    nonisolated public static let purgedMessage = "Text deleted after 90 days."

    public var body: some View {
        VStack(alignment: .leading, spacing: TFSpace.md) {
            VStack(alignment: .leading, spacing: TFSpace.xs) {
                Text(artifact.title)
                    .font(TFFont.headline)
                    .foregroundStyle(TFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail)
                        .font(TFFont.meta)
                        .foregroundStyle(TFColor.textSecondary)
                }
            }
            if artifact.isPurged {
                Text(Self.purgedMessage)
                    .font(Self.bodyFont)
                    .foregroundStyle(TFColor.textSecondary)
            } else {
                Text(artifact.body)
                    .font(Self.bodyFont)
                    .foregroundStyle(TFColor.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mac 13 (상세 칸 글과 같은 크기) · iPhone 17 (Dynamic Type `body`)
    #if os(iOS)
    private static let bodyFont = TFFont.body
    #else
    private static let bodyFont = TFFont.footnote
    #endif
}

#Preview("Draft body") {
    let now = Date()
    let draft = Artifact(
        id: UUID(), runID: UUID(), stepID: UUID(), actionID: UUID(), title: "데모 예상 질문과 답변 초안",
        body: "안녕하세요 민서 님,\n\n금요일 데모에서 나올 만한 질문을 정리했습니다.\n\n1. 결제 단계에서 이탈하는 이유는 무엇인가요?\n   — 카드 등록 화면이 두 번 나와서입니다. 새 온보딩에서 한 번으로 줄였습니다.\n2. 개인정보는 어디에 저장되나요?\n   — 서울 리전에만 저장합니다.",
        retainUntil: now.addingTimeInterval(86_400 * 90), createdAt: now
    )
    let purged = Artifact(
        id: UUID(), runID: UUID(), stepID: UUID(), actionID: UUID(), title: "견적 회신 초안", body: "",
        retainUntil: now, bodyPurgedAt: now, createdAt: now.addingTimeInterval(-86_400 * 91)
    )
    return VStack(alignment: .leading, spacing: 32) {
        DraftBody(draft, detail: "AI draft · 14:20")
        DraftBody(purged, detail: "AI draft · Jul 4")
    }
    .padding(24)
    .frame(width: 449)
    .background(TFColor.bgElevated)
}
